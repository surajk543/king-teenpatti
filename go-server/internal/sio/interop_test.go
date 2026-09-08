package sio

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// nodeModulesDir finds a node_modules with socket.io-client: $SIO_NODE_MODULES,
// then each NODE_PATH entry, then the repository's tooling package two
// directories up from the module root (tools/node_modules). "" when none.
func nodeModulesDir() string {
	candidates := []string{os.Getenv("SIO_NODE_MODULES")}
	candidates = append(candidates, filepath.SplitList(os.Getenv("NODE_PATH"))...)
	// internal/sio → go-server → repo root → tools/node_modules
	candidates = append(candidates, filepath.Join("..", "..", "..", "tools", "node_modules"))
	for _, dir := range candidates {
		if dir == "" {
			continue
		}
		if _, err := os.Stat(filepath.Join(dir, "socket.io-client", "package.json")); err == nil {
			abs, err := filepath.Abs(dir)
			if err == nil {
				return abs
			}
		}
	}
	return ""
}

// interopScript drives socket.io-client (the library behind the browser
// client, the bots and — protocol-wise — the Flutter client) against the Go
// server and prints one JSON object with everything it observed. It never
// throws past the top level: a missing step leaves its key absent and the Go
// side reports which one.
const interopScript = `
'use strict';
const { io } = require('socket.io-client');
const url = process.argv[2];
const out = { steps: [] };
const step = (name) => out.steps.push(name);
const fail = (msg) => { out.error = msg; finish(2); };
let finished = false;
const finish = (code) => {
  if (finished) return;
  finished = true;
  process.stdout.write(JSON.stringify(out));
  process.exit(code);
};
setTimeout(() => fail('timed out; steps so far: ' + out.steps.join(',')), 12000).unref();
const once = (emitter, event, ms = 4000) => new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error('no ' + event + ' within ' + ms + 'ms')), ms);
  emitter.once(event, (...args) => { clearTimeout(timer); resolve(args); });
});
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

(async () => {
  // 1. a good token connects; socket.id differs from the Engine.IO sid.
  const good = io(url, { transports: ['websocket'], auth: { token: 'good' }, reconnection: false });
  let pings = 0;
  good.io.engine.on('ping', () => { pings += 1; });
  const readyP = once(good, 'session:ready');
  await once(good, 'connect');
  step('connect');
  out.socketId = good.id;
  out.engineId = good.io.engine.id;
  out.transport = good.io.engine.transport.name;
  // 2. the server's welcome emit
  out.sessionReady = (await readyP)[0];
  step('session:ready');
  // 3. an event with an ack (socket.io-client starts ack ids at 0)
  out.quickJoinAck = await good.emitWithAck('room:quickJoin', { bootAmount: 200, category: 'blind' });
  step('ack');
  // 4. an ack with no payload
  out.leaveAckArgs = await new Promise((resolve) => good.emit('room:leave', (...args) => resolve(args)));
  step('empty ack');
  // 5. an event without an ack that the server answers with a room broadcast
  const chatP = once(good, 'chat:message');
  good.emit('chat:message', { text: 'gg "wp" <b>&' });
  out.chatEcho = (await chatP)[0];
  step('broadcast');
  // 6. heartbeat: the server pings at its short interval and the client pongs;
  //    a broken heartbeat would surface as a client-side "ping timeout".
  await sleep(700);
  out.pings = pings;
  out.stillConnected = good.connected;
  step('heartbeat');
  // 7. a rejected token: connect_error carries the middleware's code
  const bad = io(url, { transports: ['websocket'], auth: { token: 'stale' }, reconnection: false });
  const [err] = await once(bad, 'connect_error');
  out.connectErrorMessage = err && err.message;
  bad.close();
  step('connect_error');
  // 8. the server disconnects us: "41" then the transport closes
  const kickP = once(good, 'disconnect');
  good.emit('kick:me');
  out.kickReason = (await kickP)[0];
  step('server disconnect');
  // 9. a clean client-side disconnect
  const third = io(url, { transports: ['websocket'], auth: { token: 'good' }, reconnection: false });
  await once(third, 'connect');
  third.disconnect();
  step('client disconnect');
  await sleep(150);
  finish(0);
})().catch((e) => fail(String(e && e.stack || e)));
`

func TestInteropWithSocketIOClient(t *testing.T) {
	nodeBin, err := exec.LookPath("node")
	if err != nil {
		t.Skip("node not on PATH")
	}
	modules := nodeModulesDir()
	if modules == "" {
		t.Skip("socket.io-client not found (set SIO_NODE_MODULES or NODE_PATH)")
	}

	// Short heartbeat so the real client exchanges several pings within the
	// test; a wrong schedule would disconnect it with "ping timeout".
	h := newHarness(t, Options{PingInterval: 150 * time.Millisecond, PingTimeout: 300 * time.Millisecond})
	h.srv.Use(tokenMiddleware)

	var mu sync.Mutex
	var reasons []string
	var connections int
	var engineIDs []string
	h.srv.OnConnection(func(s *Socket) {
		mu.Lock()
		connections++
		mu.Unlock()
		s.Join("table-1")
		s.OnDisconnect(func(reason string) {
			mu.Lock()
			reasons = append(reasons, reason)
			mu.Unlock()
		})
		s.On("room:quickJoin", func(args []json.RawMessage, ack AckFunc) {
			var got json.RawMessage
			if len(args) > 0 {
				got = args[0]
			}
			if ack != nil {
				ack(struct {
					OK     bool            `json:"ok"`
					RoomID string          `json:"roomId"`
					Code   string          `json:"code"`
					Got    json.RawMessage `json:"got"`
				}{true, "r1", "ABC234", got})
			}
		})
		s.On("room:leave", func(_ []json.RawMessage, ack AckFunc) {
			if ack != nil {
				ack()
			}
		})
		s.On("chat:message", func(args []json.RawMessage, ack AckFunc) {
			var msg struct {
				Text string `json:"text"`
			}
			if len(args) > 0 {
				_ = json.Unmarshal(args[0], &msg)
			}
			h.srv.To("table-1").Emit("chat:message", struct {
				Text string `json:"text"`
				From string `json:"from"`
				Ack  bool   `json:"ack"`
			}{msg.Text, "server", ack != nil})
		})
		s.On("kick:me", func(_ []json.RawMessage, _ AckFunc) {
			_ = s.Emit("session:replaced", map[string]string{"message": "Signed in from another device"})
			s.Disconnect(true)
		})
		type user struct {
			ID string `json:"id"`
		}
		_ = s.Emit("session:ready", struct {
			User   user           `json:"user"`
			Config map[string]int `json:"config"`
		}{user{"u-" + s.ID()}, map[string]int{"maxPlayers": 5}})
	})
	// The connection middleware also sees the Engine.IO sid (via the OPEN
	// packet the client reports back) — collect ids to compare.
	h.srv.Use(func(s *Socket) error {
		mu.Lock()
		engineIDs = append(engineIDs, s.c.sid)
		mu.Unlock()
		return nil
	})

	dir := t.TempDir()
	script := filepath.Join(dir, "interop.cjs")
	if err := os.WriteFile(script, []byte(interopScript), 0o600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, nodeBin, script, h.ts.URL)
	cmd.Env = append(os.Environ(), "NODE_PATH="+modules)
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	runErr := cmd.Run()

	var out struct {
		Steps               []string        `json:"steps"`
		Error               string          `json:"error"`
		SocketID            string          `json:"socketId"`
		EngineID            string          `json:"engineId"`
		Transport           string          `json:"transport"`
		SessionReady        json.RawMessage `json:"sessionReady"`
		QuickJoinAck        json.RawMessage `json:"quickJoinAck"`
		LeaveAckArgs        []any           `json:"leaveAckArgs"`
		ChatEcho            json.RawMessage `json:"chatEcho"`
		Pings               int             `json:"pings"`
		StillConnected      bool            `json:"stillConnected"`
		ConnectErrorMessage string          `json:"connectErrorMessage"`
		KickReason          string          `json:"kickReason"`
	}
	if err := json.Unmarshal(stdout.Bytes(), &out); err != nil {
		t.Fatalf("node output not JSON (run error %v)\nstdout: %s\nstderr: %s", runErr, stdout.String(), stderr.String())
	}
	if runErr != nil || out.Error != "" {
		t.Fatalf("node client failed: %v / %s\nsteps: %v\nstderr: %s", runErr, out.Error, out.Steps, stderr.String())
	}
	wantSteps := "connect,session:ready,ack,empty ack,broadcast,heartbeat,connect_error,server disconnect,client disconnect"
	if got := strings.Join(out.Steps, ","); got != wantSteps {
		t.Fatalf("steps %q, want %q", got, wantSteps)
	}
	if out.Transport != "websocket" {
		t.Errorf("transport %q", out.Transport)
	}
	if out.SocketID == "" || out.EngineID == "" || out.SocketID == out.EngineID {
		t.Errorf("socket id %q / engine id %q must both be set and differ", out.SocketID, out.EngineID)
	}
	mu.Lock()
	sawEngineID := false
	for _, id := range engineIDs {
		if id == out.EngineID {
			sawEngineID = true
		}
	}
	mu.Unlock()
	if !sawEngineID {
		t.Errorf("the client's engine id %q is not one the server issued %v", out.EngineID, engineIDs)
	}
	if want := `{"user":{"id":"u-` + out.SocketID + `"},"config":{"maxPlayers":5}}`; string(out.SessionReady) != want {
		t.Errorf("session:ready %s, want %s", out.SessionReady, want)
	}
	if want := `{"ok":true,"roomId":"r1","code":"ABC234","got":{"bootAmount":200,"category":"blind"}}`; string(out.QuickJoinAck) != want {
		t.Errorf("quickJoin ack %s, want %s", out.QuickJoinAck, want)
	}
	if out.LeaveAckArgs == nil || len(out.LeaveAckArgs) != 0 {
		t.Errorf("empty ack args %v, want []", out.LeaveAckArgs)
	}
	if want := `{"text":"gg \"wp\" <b>&","from":"server","ack":false}`; string(out.ChatEcho) != want {
		t.Errorf("chat broadcast %s, want %s", out.ChatEcho, want)
	}
	if out.Pings < 3 || !out.StillConnected {
		t.Errorf("heartbeat: %d pings in 700ms at a 150ms interval, connected=%v", out.Pings, out.StillConnected)
	}
	if out.ConnectErrorMessage != "invalid_session" {
		t.Errorf("connect_error message %q, want invalid_session", out.ConnectErrorMessage)
	}
	// socket.io-client's reason for a server-side "41" + close.
	if out.KickReason != "io server disconnect" {
		t.Errorf("client-side disconnect reason %q, want \"io server disconnect\"", out.KickReason)
	}

	// Server side: two accepted sockets (the rejected one never connected),
	// one kicked, one that left with a "41".
	waitFor(t, 2*time.Second, func() bool {
		mu.Lock()
		defer mu.Unlock()
		return len(reasons) == 2
	})
	mu.Lock()
	defer mu.Unlock()
	if connections != 2 {
		t.Errorf("OnConnection ran %d times, want 2", connections)
	}
	if len(reasons) != 2 || reasons[0] != ReasonServerNamespaceDisc || reasons[1] != ReasonClientNamespaceDisc {
		t.Errorf("server-side reasons %v, want [%q %q]", reasons, ReasonServerNamespaceDisc, ReasonClientNamespaceDisc)
	}
}
