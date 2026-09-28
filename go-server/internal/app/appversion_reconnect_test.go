package app

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"sync"
	"testing"
	"time"
)

// appNodeModules finds a node_modules with socket.io-client, as the sio
// interop test does: $SIO_NODE_MODULES, NODE_PATH, then tools/node_modules.
func appNodeModules() string {
	candidates := []string{os.Getenv("SIO_NODE_MODULES")}
	candidates = append(candidates, filepath.SplitList(os.Getenv("NODE_PATH"))...)
	// internal/app → go-server → repo root → tools/node_modules
	candidates = append(candidates, filepath.Join("..", "..", "..", "tools", "node_modules"))
	for _, dir := range candidates {
		if dir == "" {
			continue
		}
		if _, err := os.Stat(filepath.Join(dir, "socket.io-client", "package.json")); err == nil {
			if abs, err := filepath.Abs(dir); err == nil {
				return abs
			}
		}
	}
	return ""
}

// reconnectScript connects twice with socket.io-client, reconnection ON, as
// every shipped client does: first as an Android build below the minimum,
// then as a supported one whose transport the test then cuts. It prints what
// each saw over the next seconds.
const reconnectScript = `
'use strict';
const { io } = require('socket.io-client');
const [url, token] = process.argv.slice(2);
const out = {};
const finish = () => { process.stdout.write(JSON.stringify(out)); process.exit(0); };
setTimeout(() => { out.error = 'timed out'; finish(); }, 15000).unref();
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
(async () => {
  // An old build: refused at the handshake. It must not knock again.
  const old = io(url, { transports: ['websocket'], forceNew: true, reconnection: true, reconnectionDelay: 100,
    auth: { token, appPlatform: 'android', appVersion: '1.4.2' } });
  out.old = { connectErrors: 0, attempts: 0, connects: 0 };
  old.on('connect_error', (e) => { out.old.connectErrors += 1; out.old.message = e.message; out.old.data = e.data; });
  old.io.on('reconnect_attempt', () => { out.old.attempts += 1; });
  old.on('connect', () => { out.old.connects += 1; });
  await sleep(2500);
  out.old.active = old.active;
  old.close();

  // A supported build whose network drops: it reconnects by itself.
  const good = io(url, { transports: ['websocket'], forceNew: true, reconnection: true, reconnectionDelay: 100,
    auth: { token, appPlatform: 'android', appVersion: '1.6.0' } });
  out.good = { connects: 0, attempts: 0 };
  good.io.on('reconnect_attempt', () => { out.good.attempts += 1; });
  good.on('connect', () => {
    out.good.connects += 1;
    if (out.good.connects === 1) process.stdout.write('CONNECTED\n');
  });
  await sleep(3500);
  good.close();
  finish();
})().catch((e) => { out.error = String(e && e.stack || e); finish(); });
`

// 11: the handshake's refusal is final. socket.io-client — reconnection on, as
// every client ships — treats a middleware refusal as the end: it does not
// knock again, so an old build refused update_required costs the server one
// handshake, not one every few hundred milliseconds for as long as the app is
// open. A network failure is different, and still reconnects on its own. (The
// Flutter client's socket_io_client does the same and stops its own retries
// on top: flutter-client/test/app_gate_socket_test.dart.)
func TestAHandshakeRefusedForAnOldVersionIsNotRetried(t *testing.T) {
	nodeBin, err := exec.LookPath("node")
	if err != nil {
		t.Skip("node not on PATH")
	}
	modules := appNodeModules()
	if modules == "" {
		t.Skip("socket.io-client not found (npm install in tools/, or set SIO_NODE_MODULES)")
	}
	a, database, ts := newGatedApp(t, false)
	token, _ := login(t, ts.URL, "appver-reconnect-device-01", "Knocker")
	setVersions(t, database, "android", "1.5.0", "0.0.0")

	// The client reaches the server through a proxy the test can cut, as a
	// phone's network goes.
	network := newCuttableProxy(t, ts.Listener.Addr().String())

	script := filepath.Join(t.TempDir(), "reconnect.cjs")
	if err := os.WriteFile(script, []byte(reconnectScript), 0o600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, nodeBin, script, "http://"+network.addr(), token)
	cmd.Env = append(os.Environ(), "NODE_PATH="+modules)
	var stderr bytes.Buffer
	stdout := &lineWatcher{seen: make(chan struct{})}
	cmd.Stdout, cmd.Stderr = stdout, &stderr
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	// Once the supported client is in, cut every connection: its transport
	// drops as a phone's does when the network goes.
	select {
	case <-stdout.seen:
		time.Sleep(200 * time.Millisecond)
		network.cut()
	case <-ctx.Done():
	}
	if err := cmd.Wait(); err != nil {
		t.Fatalf("node: %v\n%s", err, stderr.String())
	}

	var out struct {
		Error string `json:"error"`
		Old   struct {
			ConnectErrors int             `json:"connectErrors"`
			Attempts      int             `json:"attempts"`
			Connects      int             `json:"connects"`
			Active        bool            `json:"active"`
			Message       string          `json:"message"`
			Data          json.RawMessage `json:"data"`
		} `json:"old"`
		Good struct {
			Connects int `json:"connects"`
			Attempts int `json:"attempts"`
		} `json:"good"`
	}
	body := stdout.buf.Bytes()
	if i := bytes.LastIndexByte(body, '\n'); i >= 0 {
		body = body[i+1:]
	}
	if err := json.Unmarshal(body, &out); err != nil || out.Error != "" {
		t.Fatalf("node output %q (%v)\nstderr: %s", stdout.buf.String(), err, stderr.String())
	}
	if out.Old.ConnectErrors != 1 || out.Old.Attempts != 0 || out.Old.Connects != 0 || out.Old.Active {
		t.Errorf("the refused client: %+v — want one connect_error, no reconnect attempt, inactive", out.Old)
	}
	if out.Old.Message != "update_required" || !bytes.Contains(out.Old.Data, []byte(`"minimumVersion":"1.5.0"`)) {
		t.Errorf("the refused client heard %q %s", out.Old.Message, out.Old.Data)
	}
	if out.Good.Connects < 2 || out.Good.Attempts < 1 {
		t.Errorf("the supported client after a network drop: %+v — want it to reconnect by itself", out.Good)
	}

	// The server saw the old build knock once.
	res, metricsBody := get(t, a.Handler(), http.MethodGet, "/metrics", func(r *http.Request) { r.Header.Set("Authorization", "Bearer "+metricsToken) })
	m := regexp.MustCompile(`game_app_version_rejections_total\{platform="android",service="king-teenpatti",status="force_update",via="socket"\} (\d+)`).FindSubmatch(metricsBody)
	if res.StatusCode != http.StatusOK || m == nil {
		t.Fatalf("no socket rejection counted:\n%s", grepLines(string(metricsBody), "game_app_version"))
	}
	if n, _ := strconv.Atoi(string(m[1])); n != 1 {
		t.Errorf("the old build was refused %d times at the handshake in 2.5 s, want 1", n)
	}
}

// cuttableProxy forwards TCP connections to target; cut closes every one open
// (a network drop) and it goes on accepting new ones.
type cuttableProxy struct {
	ln     net.Listener
	target string
	mu     sync.Mutex
	conns  []net.Conn
}

func newCuttableProxy(t *testing.T, target string) *cuttableProxy {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	p := &cuttableProxy{ln: ln, target: target}
	go func() {
		for {
			in, err := ln.Accept()
			if err != nil {
				return
			}
			out, err := net.Dial("tcp", target)
			if err != nil {
				_ = in.Close()
				continue
			}
			p.mu.Lock()
			p.conns = append(p.conns, in, out)
			p.mu.Unlock()
			go func() { _, _ = io.Copy(out, in); _ = out.Close() }()
			go func() { _, _ = io.Copy(in, out); _ = in.Close() }()
		}
	}()
	t.Cleanup(func() { _ = ln.Close(); p.cut() })
	return p
}

func (p *cuttableProxy) addr() string { return p.ln.Addr().String() }

func (p *cuttableProxy) cut() {
	p.mu.Lock()
	conns := p.conns
	p.conns = nil
	p.mu.Unlock()
	for _, c := range conns {
		_ = c.Close()
	}
}

// lineWatcher is the node process's stdout: it closes seen at the first
// "CONNECTED" line.
type lineWatcher struct {
	buf    bytes.Buffer
	seen   chan struct{}
	closed bool
}

func (w *lineWatcher) Write(p []byte) (int, error) {
	n, err := w.buf.Write(p)
	if !w.closed && bytes.Contains(w.buf.Bytes(), []byte("CONNECTED\n")) {
		w.closed = true
		close(w.seen)
	}
	return n, err
}
