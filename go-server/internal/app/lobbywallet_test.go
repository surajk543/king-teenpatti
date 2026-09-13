package app

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/auth"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/purchase"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket/testclient"
)

// socketDoor is one socket event that seats a player from the lobby. payload
// builds its body (a table it needs is made there, before the race starts);
// frame is the RoomManager method in which the join waits for the player's
// seat lock.
type socketDoor struct {
	event   string
	frame   string
	payload func(a *App) map[string]any
}

// socketDoors are every lobby door the socket layer has. Each reads the wallet
// in its own RoomManager method, so each is raced on its own. room:joinCode is
// also the door the resume offer's auto-join comes through.
var socketDoors = []socketDoor{
	{
		event: socket.EvRoomQuickJoin,
		frame: "(*RoomManager).QuickJoin(",
		payload: func(*App) map[string]any {
			return map[string]any{"bootAmount": 200, "category": "seen"}
		},
	},
	{
		event: socket.EvRoomJoinCode,
		frame: "(*RoomManager).JoinByCode(",
		payload: func(a *App) map[string]any {
			table := a.Rooms().CreateTable(game.CreateTableOptions{BootAmount: 200, Category: "seen"})
			return map[string]any{"code": table.Code()}
		},
	},
	{
		// A private table (isPrivate defaults to true).
		event:   socket.EvRoomCreate,
		frame:   "(*RoomManager).CreateAndJoin(",
		payload: func(*App) map[string]any { return map[string]any{} },
	},
	{
		// A public one, whose chip checks read the same wallet.
		event: socket.EvRoomCreate,
		frame: "(*RoomManager).CreateAndJoin(",
		payload: func(*App) map[string]any {
			return map[string]any{"isPrivate": false, "bootAmount": 200, "category": "seen"}
		},
	},
}

// The lobby-wallet race end to end, on the real wiring: POST
// /api/profile/picture/buy through rooms.WhileUnseated, each lobby socket door
// through the socket layer and RoomManagerOptions.LoadPlayer, PostgreSQL
// underneath.
//
// A player holding 2,50,000 buys a 2,00,000 COIN picture. The purchase is
// stopped between its seated check and its commit by holding the wallet row
// from another transaction, so Pictures.Buy waits on its SELECT … FOR UPDATE.
// The same player's join arrives while it waits. Before the fix the join read
// 2,50,000 — a plain SELECT does not wait on a row lock — and seated it at
// once; the wallet then fell to 50,000 behind the seat. Now the join waits on
// the seat lock the purchase holds, and seats what the purchase left.
func TestALobbyPictureAndAJoinCannotSeatAStaleWallet(t *testing.T) {
	a, database := newApp(t, nil)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()

	for i, door := range socketDoors {
		t.Run(fmt.Sprintf("%s/%d", door.event, i), func(t *testing.T) {
			raceLobbyPicture(t, a, ts.URL, database, door, i)
		})
	}

	// No race: a seated player is refused a chip-priced picture and both
	// rewards 409 seated by the same lock, a diamond picture still sells at the
	// table, and back in the lobby the chip-priced picture sells as it always
	// did.
	token, id := login(t, ts.URL, "lobby-wallet-sitter", "Sitter")
	c := dial(t, ts.URL, token)
	mustOK(t, c, socket.EvRoomQuickJoin, map[string]any{"bootAmount": 200, "category": "seen"})
	if a.Rooms().GetTableForPlayer(id) == nil {
		t.Fatal("the sitter is not seated after a plain quick join")
	}
	mule := insertPicture(t, database, "Race Mule", "COIN", 1_000)
	gem := insertPicture(t, database, "Race Gem", "DIAMOND", 1)
	if res := postJSON(ts.URL, token, "/api/profile/picture/buy", map[string]any{"pictureId": mule}); res.err != nil || res.status != http.StatusConflict || res.body["error"] != auth.CodeSeated {
		t.Errorf("seated coin buy: %d %v %v", res.status, res.body, res.err)
	}
	for _, path := range []string{"/api/rewards/milestone", "/api/rewards/bonus"} {
		if res := postJSON(ts.URL, token, path, map[string]any{}); res.err != nil || res.status != http.StatusConflict || res.body["error"] != auth.CodeSeated {
			t.Errorf("seated %s: %d %v %v", path, res.status, res.body, res.err)
		}
	}
	if res := postJSON(ts.URL, token, "/api/profile/picture/buy", map[string]any{"pictureId": gem}); res.err != nil || res.status != http.StatusOK || res.body["charged"] != true {
		t.Errorf("seated diamond buy: %d %v %v", res.status, res.body, res.err)
	}
	welcome := a.cfg.Game.WelcomeChips
	if wallet, _ := walletAndLedger(t, database, id); wallet != welcome {
		t.Errorf("chips moved while seated: wallet %d, want %d", wallet, welcome)
	}

	mustOK(t, c, socket.EvRoomLeave, map[string]any{})
	if res := postJSON(ts.URL, token, "/api/profile/picture/buy", map[string]any{"pictureId": mule}); res.err != nil || res.status != http.StatusOK || res.body["charged"] != true {
		t.Fatalf("lobby coin buy: %d %v %v", res.status, res.body, res.err)
	}
	if wallet, ledger := walletAndLedger(t, database, id); wallet != welcome-1_000 || ledger != wallet {
		t.Errorf("after the lobby buy: wallet %d, ledger %d, want both %d", wallet, ledger, welcome-1_000)
	}
}

// raceLobbyPicture pauses a lobby picture purchase inside its transaction,
// sends the same player's join through door while it waits, and checks that
// the seat, the wallet and the ledger all say 50,000 once both have finished.
func raceLobbyPicture(t *testing.T, a *App, baseURL string, database *db.DB, door socketDoor, n int) {
	t.Helper()
	ctx := context.Background()
	token, id := login(t, baseURL, fmt.Sprintf("lobby-wallet-race-%02d", n), "Racer")
	grantWallet(t, a, database, id, 250_000, fmt.Sprintf("lobby-wallet-race-grant-%02d", n))
	coin := insertPicture(t, database, fmt.Sprintf("Race Horse %d", n), "COIN", 200_000)
	c := dial(t, baseURL, token)
	payload := door.payload(a)

	// Hold the wallet row: the purchase will pass its seated check, take the
	// seat lock, and then wait inside its transaction for this one.
	hold, holder := holdWallet(t, database, id)
	defer func() { _ = hold.Rollback(ctx) }()

	bought := make(chan restAnswer, 1)
	go func() {
		bought <- postJSON(baseURL, token, "/api/profile/picture/buy", map[string]any{"pictureId": coin})
	}()
	waitBlockedBy(t, database, holder)

	joined := make(chan socketAnswer, 1)
	go func() {
		ack, err := c.Call(door.event, payload, 10*time.Second)
		joined <- socketAnswer{ack, err}
	}()
	waitParkedOnLock(t, door.frame)

	// Let the purchase commit; the join may only read the wallet after it.
	if err := hold.Rollback(ctx); err != nil {
		t.Fatal(err)
	}
	var buy restAnswer
	select {
	case buy = <-bought:
	case <-time.After(10 * time.Second):
		t.Fatal("the purchase never finished once the wallet row was released")
	}
	if buy.err != nil || buy.status != http.StatusOK || buy.body["charged"] != true {
		t.Fatalf("buy: %d %v %v", buy.status, buy.body, buy.err)
	}
	// c.Call gives up after 10 s on its own, so this receive cannot hang.
	if join := <-joined; join.err != nil || !join.ack.OK {
		t.Fatalf("%s: %v %s", door.event, join.err, join.ack.Raw)
	}
	if seat, wallet, ledger := seatOf(t, a, id), walletOf(t, database, id), ledgerOf(t, database, id); seat != 50_000 || wallet != 50_000 || ledger != 50_000 {
		t.Fatalf("seat %d, wallet %d, ledger %d: all three must be 50,000", seat, wallet, ledger)
	}

	// Leave, so the next door's quick join cannot land on this table and start
	// a hand under the next racer.
	mustOK(t, c, socket.EvRoomLeave, map[string]any{})
	if wallet, ledger := walletAndLedger(t, database, id); wallet != 50_000 || ledger != wallet {
		t.Fatalf("after leaving: wallet %d, ledger %d, want both 50,000", wallet, ledger)
	}
}

// A Google Play chip pack end to end, on the real wiring: playStore.Buy with
// its verifier answered in process (fakePlay), rooms.CreditBoughtChips, a
// socket room:quickJoin and PostgreSQL underneath.
//
// The pack is stopped after its credit has committed and before its seat
// top-up: the moment a join used to read the wallet with the pack already in
// it and sit down in time for the top-up to find the seat and add the pack
// again — chips that existed only on the seat, which a lost hand then paid out
// past a wallet clamped at zero. The join waits instead, and the seat, the
// wallet and the ledger agree. Then the player, seated, buys another pack
// through the production wiring (it reaches the seat once) and replays its
// receipt (it reaches nothing).
func TestAChipPackAndAJoinNeverPutThePackOnTheSeatTwice(t *testing.T) {
	a, database := newApp(t, nil)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	ctx := context.Background()

	token, id := login(t, ts.URL, "lobby-wallet-chip-pack", "Packer")
	grantWallet(t, a, database, id, 250_000, "lobby-wallet-chip-pack-grant")
	product, err := purchase.Lookup("chips_a_99")
	if err != nil {
		t.Fatal(err)
	}
	c := dial(t, ts.URL, token)
	users := db.NewUsers(database, a.cfg.Game.WelcomeChips, time.Now)
	verifier := newFakePlayVerifier(t)

	paused, gate := make(chan struct{}), make(chan struct{})
	var once sync.Once
	release := func() { once.Do(func() { close(gate) }) }
	defer release()
	store := &playStore{
		verifier: verifier,
		db:       database,
		users:    users,
		// rooms.CreditBoughtChips, as app.New wires it, with a pause between
		// the credit and the top-up.
		credit: func(userID string, amount int64, bank func(context.Context) bool) bool {
			return a.Rooms().CreditBoughtChips(userID, amount, func(bctx context.Context) bool {
				credited := bank(bctx)
				close(paused)
				<-gate
				return credited
			})
		},
	}
	type buyAnswer struct {
		out auth.PurchaseOutcome
		err error
	}
	bought := make(chan buyAnswer, 1)
	go func() {
		out, err := store.Buy(ctx, id, product.ID, "fake-play-receipt-1")
		bought <- buyAnswer{out, err}
	}()
	select {
	case <-paused:
	case <-time.After(10 * time.Second):
		t.Fatal("the chip pack never reached its seat top-up")
	}
	afterPack := 250_000 + product.Chips
	if wallet, ledger := walletAndLedger(t, database, id); wallet != afterPack || ledger != wallet {
		t.Fatalf("paused after its credit: wallet %d, ledger %d, want both %d", wallet, ledger, afterPack)
	}

	joined := make(chan socketAnswer, 1)
	go func() {
		ack, err := c.Call(socket.EvRoomQuickJoin, map[string]any{"bootAmount": 200, "category": "seen"}, 10*time.Second)
		joined <- socketAnswer{ack, err}
	}()
	waited := waitParkedOrAnswered(t, "(*RoomManager).QuickJoin(", joined)

	release()
	var buy buyAnswer
	select {
	case buy = <-bought:
	case <-time.After(10 * time.Second):
		t.Fatal("the chip pack never finished once it was let go")
	}
	if buy.err != nil || !buy.out.Credited || buy.out.Chips != product.Chips {
		t.Fatalf("buy: %+v %v", buy.out, buy.err)
	}
	// c.Call gives up after 10 s on its own, so this receive cannot hang.
	if join := <-joined; join.err != nil || !join.ack.OK {
		t.Fatalf("quick join: %v %s", join.err, join.ack.Raw)
	}
	if seat, wallet, ledger := seatOf(t, a, id), walletOf(t, database, id), ledgerOf(t, database, id); seat != afterPack || wallet != afterPack || ledger != afterPack {
		t.Fatalf("seat %d, wallet %d, ledger %d: all three must be %d (the join waited for the pack's seat lock: %v)", seat, wallet, ledger, afterPack, waited)
	}
	if !waited {
		t.Fatal("the join did not wait for a chip pack that held the seat lock")
	}

	// Seated: a second pack through the production wiring reaches the seat
	// once, and its receipt replayed reaches neither the wallet nor the seat.
	seated := &playStore{verifier: verifier, db: database, users: users, credit: a.Rooms().CreditBoughtChips}
	if out, err := seated.Buy(ctx, id, product.ID, "fake-play-receipt-2"); err != nil || !out.Credited {
		t.Fatalf("seated buy: %+v %v", out, err)
	}
	afterTwo := afterPack + product.Chips
	if seat, wallet, ledger := seatOf(t, a, id), walletOf(t, database, id), ledgerOf(t, database, id); seat != afterTwo || wallet != afterTwo || ledger != afterTwo {
		t.Fatalf("after a seated pack: seat %d, wallet %d, ledger %d, want all %d", seat, wallet, ledger, afterTwo)
	}
	if out, err := seated.Buy(ctx, id, product.ID, "fake-play-receipt-2"); err != nil || out.Credited {
		t.Fatalf("replayed receipt: %+v %v, want an answer that credits nothing", out, err)
	}
	if seat, wallet := seatOf(t, a, id), walletOf(t, database, id); seat != afterTwo || wallet != afterTwo {
		t.Fatalf("after a replayed receipt: seat %d, wallet %d, want both %d", seat, wallet, afterTwo)
	}

	mustOK(t, c, socket.EvRoomLeave, map[string]any{})
	if wallet, ledger := walletAndLedger(t, database, id); wallet != afterTwo || ledger != wallet {
		t.Fatalf("after leaving: wallet %d, ledger %d, want both %d", wallet, ledger, afterTwo)
	}
}

// A client hanging up in the middle of a lobby picture purchase must not
// shorten the seat lock. The purchase is held inside its transaction (the
// wallet row locked from another), its request is cancelled, and the same
// player's join is sent. The purchase goes on waiting — its context is the seat
// lock's, not the request's — so the join waits with it; when the row is let
// go the purchase commits, and the join seats what it left. On the request's
// context, pgx would have given up at the hang-up and the lock gone with it,
// with the transaction still undecided.
func TestACancelledPictureRequestKeepsTheSeatLockUntilItsOutcomeIsFinal(t *testing.T) {
	a, database := newApp(t, nil)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	ctx := context.Background()

	token, id := login(t, ts.URL, "lobby-wallet-hang-up", "HangUp")
	grantWallet(t, a, database, id, 250_000, "lobby-wallet-hang-up-grant")
	coin := insertPicture(t, database, "Hang Up Horse", "COIN", 200_000)
	c := dial(t, ts.URL, token)

	hold, holder := holdWallet(t, database, id)
	defer func() { _ = hold.Rollback(ctx) }()

	requestCtx, hangUp := context.WithCancel(ctx)
	defer hangUp()
	answered := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		body, _ := json.Marshal(map[string]any{"pictureId": coin})
		req := httptest.NewRequestWithContext(requestCtx, http.MethodPost, "/api/profile/picture/buy", bytes.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Authorization", "Bearer "+token)
		rec := httptest.NewRecorder()
		a.Handler().ServeHTTP(rec, req)
		answered <- rec
	}()
	waitBlockedBy(t, database, holder)

	hangUp()
	select {
	case rec := <-answered:
		t.Fatalf("the purchase answered %d the moment its client hung up, letting the seat lock go with its transaction undecided: %s", rec.Code, rec.Body.String())
	case <-time.After(300 * time.Millisecond):
	}

	joined := make(chan socketAnswer, 1)
	go func() {
		ack, err := c.Call(socket.EvRoomQuickJoin, map[string]any{"bootAmount": 200, "category": "seen"}, 10*time.Second)
		joined <- socketAnswer{ack, err}
	}()
	waitParkedOnLock(t, "(*RoomManager).QuickJoin(")

	if err := hold.Rollback(ctx); err != nil {
		t.Fatal(err)
	}
	var rec *httptest.ResponseRecorder
	select {
	case rec = <-answered:
	case <-time.After(10 * time.Second):
		t.Fatal("the purchase never finished once the wallet row was released")
	}
	if rec.Code != http.StatusOK {
		t.Fatalf("buy after the hang-up: %d %s", rec.Code, rec.Body.String())
	}
	// c.Call gives up after 10 s on its own, so this receive cannot hang.
	if join := <-joined; join.err != nil || !join.ack.OK {
		t.Fatalf("quick join: %v %s", join.err, join.ack.Raw)
	}
	if seat, wallet, ledger := seatOf(t, a, id), walletOf(t, database, id), ledgerOf(t, database, id); seat != 50_000 || wallet != 50_000 || ledger != 50_000 {
		t.Fatalf("seat %d, wallet %d, ledger %d: all three must be 50,000", seat, wallet, ledger)
	}
	mustOK(t, c, socket.EvRoomLeave, map[string]any{})
}

// fakePlay answers, in process, the three Google endpoints a chip pack
// touches: the service-account token exchange, the receipt, and the
// acknowledgement. Nothing leaves the machine.
type fakePlay struct{}

func (fakePlay) RoundTrip(req *http.Request) (*http.Response, error) {
	if req.Body != nil {
		_, _ = io.Copy(io.Discard, req.Body)
		_ = req.Body.Close()
	}
	reply := func(status int, body string) (*http.Response, error) {
		return &http.Response{
			StatusCode: status,
			Header:     http.Header{"Content-Type": {"application/json"}},
			Body:       io.NopCloser(strings.NewReader(body)),
			Request:    req,
		}, nil
	}
	switch {
	case req.URL.Host == "oauth2.fake-play.test":
		return reply(http.StatusOK, `{"access_token":"fake-play-access","expires_in":3600}`)
	case req.Method == http.MethodPost && strings.HasSuffix(req.URL.Path, ":acknowledge"):
		return reply(http.StatusOK, `{}`)
	case req.Method == http.MethodGet && strings.Contains(req.URL.Path, "/purchases/products/"):
		return reply(http.StatusOK, `{"purchaseState":0,"acknowledgementState":0,"orderId":"GPA.fake-play","purchaseTimeMillis":"1"}`)
	}
	return reply(http.StatusNotFound, `{}`)
}

// newFakePlayVerifier is a real purchase.GoogleVerifier — a freshly made
// service-account key, its own JWT assertion — whose HTTP goes to fakePlay.
func newFakePlayVerifier(t *testing.T) *purchase.GoogleVerifier {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	account, err := json.Marshal(map[string]string{
		"client_email": "store@fake-play.test",
		"private_key":  string(pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)})),
		"token_uri":    "https://oauth2.fake-play.test/token",
	})
	if err != nil {
		t.Fatal(err)
	}
	verifier, err := purchase.NewGoogleVerifier("com.sungamestudio.kingteenpatti", string(account))
	if err != nil || verifier == nil {
		t.Fatalf("verifier: %v", err)
	}
	verifier.HTTP = &http.Client{Transport: fakePlay{}, Timeout: 5 * time.Second}
	return verifier
}

// grantWallet sets a fresh account's wallet to chips through a test_fixture
// ledger row, so SUM(delta) keeps matching the wallet.
func grantWallet(t *testing.T, a *App, database *db.DB, userID string, chips int64, actionID string) {
	t.Helper()
	users := db.NewUsers(database, a.cfg.Game.WelcomeChips, time.Now)
	if _, err := users.ApplyChipDelta(context.Background(), userID, chips-a.cfg.Game.WelcomeChips, "test_fixture", "", actionID); err != nil {
		t.Fatal(err)
	}
}

// holdWallet locks the account's users row from a transaction of its own and
// returns it with its backend pid, so a purchase can be held inside its
// SELECT … FOR UPDATE until the caller rolls this back.
func holdWallet(t *testing.T, database *db.DB, userID string) (hold interface {
	Rollback(context.Context) error
}, holder int32) {
	t.Helper()
	ctx := context.Background()
	tx, err := database.Pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := tx.QueryRow(ctx, `SELECT pg_backend_pid()`).Scan(&holder); err != nil {
		_ = tx.Rollback(ctx)
		t.Fatal(err)
	}
	if err := tx.QueryRow(ctx, `SELECT chips FROM users WHERE id = $1 FOR UPDATE`, userID).Scan(new(int64)); err != nil {
		_ = tx.Rollback(ctx)
		t.Fatal(err)
	}
	return tx, holder
}

// insertPicture adds a premium catalogue row priced in currency.
func insertPicture(t *testing.T, database *db.DB, name, currency string, cost int64) int64 {
	t.Helper()
	url := "/profiles/" + strings.ToLower(strings.ReplaceAll(name, " ", "-")) + ".svg"
	var id int64
	if err := database.Pool.QueryRow(context.Background(),
		`INSERT INTO profile_pictures (name, asset_url, asset_format, type, currency, cost, created_at, updated_at)
		 VALUES ($1, $2, 'SVG', 'PREMIUM', $3, $4, 0, 0) RETURNING id`, name, url, currency, cost).Scan(&id); err != nil {
		t.Fatalf("insert picture %s: %v", name, err)
	}
	return id
}

// walletAndLedger is users.chips and SUM(chip_ledger.delta) for one account.
func walletAndLedger(t *testing.T, database *db.DB, userID string) (wallet, ledger int64) {
	t.Helper()
	if err := database.Pool.QueryRow(context.Background(),
		`SELECT chips, (SELECT COALESCE(SUM(delta), 0)::bigint FROM chip_ledger WHERE user_id = $1) FROM users WHERE id = $1`,
		userID).Scan(&wallet, &ledger); err != nil {
		t.Fatal(err)
	}
	return wallet, ledger
}

func walletOf(t *testing.T, database *db.DB, userID string) int64 {
	t.Helper()
	wallet, _ := walletAndLedger(t, database, userID)
	return wallet
}

func ledgerOf(t *testing.T, database *db.DB, userID string) int64 {
	t.Helper()
	_, ledger := walletAndLedger(t, database, userID)
	return ledger
}

// seatOf is the chips on the player's live seat, failing when there is none.
func seatOf(t *testing.T, a *App, userID string) int64 {
	t.Helper()
	table := a.Rooms().GetTableForPlayer(userID)
	if table == nil {
		t.Fatal("the player is not seated")
	}
	seat, err := table.FindSeat(userID)
	if err != nil || seat == nil {
		t.Fatalf("seat: %v", err)
	}
	return seat.Chips
}

type restAnswer struct {
	status int
	body   map[string]any
	err    error
}

type socketAnswer struct {
	ack testclient.Ack
	err error
}

// postJSON is one authenticated REST call. It reports failures rather than
// failing the test, so it can run off the test goroutine.
func postJSON(baseURL, token, path string, body any) restAnswer {
	raw, _ := json.Marshal(body)
	req, err := http.NewRequest(http.MethodPost, baseURL+path, bytes.NewReader(raw))
	if err != nil {
		return restAnswer{err: err}
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		return restAnswer{err: err}
	}
	defer res.Body.Close()
	data, _ := io.ReadAll(res.Body)
	out := restAnswer{status: res.StatusCode}
	if err := json.Unmarshal(data, &out.body); err != nil {
		out.err = fmt.Errorf("%s: %w", data, err)
	}
	return out
}

// waitBlockedBy waits until some session is waiting on a lock the backend
// holder holds.
func waitBlockedBy(t *testing.T, database *db.DB, holder int32) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		var waiting int
		if err := database.Pool.QueryRow(context.Background(),
			`SELECT count(*) FROM pg_stat_activity WHERE $1 = ANY(pg_blocking_pids(pid))`, holder).Scan(&waiting); err != nil {
			t.Fatal(err)
		}
		if waiting > 0 {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("the purchase never waited on the held wallet row")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

// waitParkedOnLock waits until some goroutine is blocked taking a sync.Mutex
// inside a function whose name contains frame — here, the join waiting for the
// player's seat lock. It is how the test knows the join got as far as it can
// while the purchase is paused, with no seam in the production code. (The game
// package's tests carry the same helper; test files cannot share one.)
func waitParkedOnLock(t *testing.T, frame string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !parkedOnLock(frame) {
		if time.Now().After(deadline) {
			t.Fatalf("no goroutine is waiting for a lock in %s", frame)
		}
		time.Sleep(time.Millisecond)
	}
}

// waitParkedOrAnswered is waitParkedOnLock for a join a broken lock would let
// straight through: true once it waits on a lock in frame, false once it has
// already been answered (answered holds the answer, unread), so the test can
// go on to say what that did to the money.
func waitParkedOrAnswered(t *testing.T, frame string, answered chan socketAnswer) bool {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		if len(answered) > 0 {
			return false
		}
		if parkedOnLock(frame) {
			return true
		}
		if time.Now().After(deadline) {
			t.Fatalf("the join neither waited for a lock in %s nor was answered", frame)
		}
		time.Sleep(time.Millisecond)
	}
}

func parkedOnLock(frame string) bool {
	buf := make([]byte, 1<<20)
	n := runtime.Stack(buf, true)
	for n == len(buf) {
		buf = make([]byte, 2*len(buf))
		n = runtime.Stack(buf, true)
	}
	for _, g := range strings.Split(string(buf[:n]), "\n\n") {
		if strings.Contains(g, "[sync.Mutex.Lock") && strings.Contains(g, frame) {
			return true
		}
	}
	return false
}
