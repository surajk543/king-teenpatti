package app

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/db/dbtest"
	"github.com/surajk543/king-teenpatti/go-server/internal/livetest"
	"github.com/surajk543/king-teenpatti/go-server/internal/purchase/appletest"
	"github.com/surajk543/king-teenpatti/go-server/internal/socket"
	"github.com/surajk543/king-teenpatti/go-server/internal/util"
)

const iosBundle = "com.sungamestudio.kingteenpatti"

// newAppleApp is newApp whose App Store till trusts signer's root in place
// of Apple's — everything else is the real wiring: the route, the verifier,
// the till and the database.
func newAppleApp(t *testing.T, mutate func(*config.Config)) (*App, *db.DB, *appletest.Signer) {
	t.Helper()
	database := dbtest.Open(t, "app")
	cfg := testConfig(t, publicDir(t))
	if mutate != nil {
		mutate(cfg)
	}
	signer := appletest.New(t, appletest.Options{})
	a, err := New(Options{
		Config: cfg, DB: database, Logger: util.NewLogger("error", io.Discard),
		Live: livetest.New(), AppleRoots: signer.Roots,
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
		defer cancel()
		if err := a.Shutdown(ctx); err != nil {
			t.Errorf("Shutdown: %v", err)
		}
	})
	return a, database, signer
}

func appleBuy(t *testing.T, baseURL, token, productID, transaction string) restAnswer {
	t.Helper()
	out := postJSON(baseURL, token, "/api/purchases/apple", map[string]any{"productId": productID, "transaction": transaction})
	if out.err != nil {
		t.Fatalf("POST /api/purchases/apple: %v", out.err)
	}
	return out
}

func num(t *testing.T, body map[string]any, key string) int64 {
	t.Helper()
	f, ok := body[key].(float64)
	if !ok {
		t.Fatalf("%s is %v (%T) in %v", key, body[key], body[key], body)
	}
	return int64(f)
}

// A chip pack bought on an iPhone: the signed transaction StoreKit hands the
// app, posted to POST /api/purchases/apple, is banked once through the
// ledger under "appstore:<transactionId>", and delivered again — by the same
// account or another — credits nothing.
func TestAnAppStoreChipPackIsBankedOnceThroughTheLedger(t *testing.T) {
	a, database, signer := newAppleApp(t, nil)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()

	token, id := login(t, ts.URL, "iphone-chip-buyer", "Asha")
	wallet0, _ := walletAndLedger(t, database, id)
	jws := signer.Sign(t, appletest.Transaction{TransactionID: "2000000900000001", BundleID: iosBundle, ProductID: "chips_a_99"})

	out := appleBuy(t, ts.URL, token, "chips_a_99", jws)
	if out.status != http.StatusOK || out.body["credited"] != true || num(t, out.body, "chips") != 19_200_000 ||
		num(t, out.body, "balance") != wallet0+19_200_000 || out.body["user"] == nil {
		t.Fatalf("first delivery: %d %v", out.status, out.body)
	}
	for _, key := range []string{"diamonds", "hammers", "missiles"} {
		if num(t, out.body, key) != 0 {
			t.Fatalf("a chip pack answered %s = %v", key, out.body[key])
		}
	}
	wallet, ledger := walletAndLedger(t, database, id)
	if wallet != wallet0+19_200_000 || ledger != wallet {
		t.Fatalf("wallet %d, ledger %d, want both %d", wallet, ledger, wallet0+19_200_000)
	}
	var reason string
	var delta int64
	if err := database.Pool.QueryRow(context.Background(),
		`SELECT reason, delta FROM chip_ledger WHERE action_id = 'appstore:2000000900000001'`).Scan(&reason, &delta); err != nil {
		t.Fatalf("the purchase's ledger row: %v", err)
	}
	if reason != "purchase" || delta != 19_200_000 {
		t.Fatalf("ledger row: %s %d", reason, delta)
	}

	// StoreKit delivers an unfinished transaction again: the app must be
	// told it is banked (200), and nothing moves.
	again := appleBuy(t, ts.URL, token, "chips_a_99", jws)
	if again.status != http.StatusOK || again.body["credited"] != false || num(t, again.body, "balance") != wallet {
		t.Fatalf("second delivery: %d %v", again.status, again.body)
	}
	// The same transaction from another account buys that account nothing.
	otherToken, otherID := login(t, ts.URL, "iphone-chip-thief", "Other")
	otherWallet, _ := walletAndLedger(t, database, otherID)
	stolen := appleBuy(t, ts.URL, otherToken, "chips_a_99", jws)
	if stolen.status != http.StatusOK || stolen.body["credited"] != false {
		t.Fatalf("another account's delivery: %d %v", stolen.status, stolen.body)
	}
	if w, l := walletAndLedger(t, database, otherID); w != otherWallet || l != otherWallet {
		t.Fatalf("another account's wallet moved: %d → %d (ledger %d)", otherWallet, w, l)
	}
	if w, _ := walletAndLedger(t, database, id); w != wallet {
		t.Fatalf("the buyer's wallet moved on a replay: %d → %d", wallet, w)
	}
}

// Every kind of product the store sells is sold on the App Store under the
// same id and lands where its Play purchase would: diamonds and hammers in
// their wallets with no ledger row, a premium package's three together, a
// badge as its grant.
func TestEveryKindOfProductSellsOnTheAppStore(t *testing.T) {
	a, database, signer := newAppleApp(t, nil)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	ctx := context.Background()

	token, id := login(t, ts.URL, "iphone-everything-buyer", "Asha")
	wallet0, _ := walletAndLedger(t, database, id)
	diamonds0, missiles0, hammers0 := softWallets(t, database, id)
	sign := func(tx, product string) string {
		return signer.Sign(t, appletest.Transaction{TransactionID: tx, BundleID: iosBundle, ProductID: product, Environment: "Sandbox"})
	}

	d := appleBuy(t, ts.URL, token, "diamonds_20_699", sign("11", "diamonds_20_699"))
	if d.status != http.StatusOK || d.body["credited"] != true || num(t, d.body, "diamonds") != 20 || num(t, d.body, "chips") != 0 {
		t.Fatalf("diamonds: %d %v", d.status, d.body)
	}
	h := appleBuy(t, ts.URL, token, "hammers_50_699", sign("12", "hammers_50_699"))
	if h.status != http.StatusOK || h.body["credited"] != true || num(t, h.body, "hammers") != 50 || num(t, h.body, "chips") != 0 {
		t.Fatalf("hammers: %d %v", h.status, h.body)
	}
	if w, l := walletAndLedger(t, database, id); w != wallet0 || l != wallet0 {
		t.Fatalf("a diamond or hammer pack moved chips: %d → %d (ledger %d)", wallet0, w, l)
	}

	p := appleBuy(t, ts.URL, token, "premium_1_9999", sign("13", "premium_1_9999"))
	if p.status != http.StatusOK || p.body["credited"] != true || num(t, p.body, "chips") != 6_500_000_000 ||
		num(t, p.body, "missiles") != 1 || num(t, p.body, "hammers") != 10 {
		t.Fatalf("premium package: %d %v", p.status, p.body)
	}
	diamonds, missiles, hammers := softWallets(t, database, id)
	if diamonds != diamonds0+20 || missiles != missiles0+1 || hammers != hammers0+50+10 {
		t.Fatalf("wallets: diamonds %d→%d, missiles %d→%d, hammers %d→%d", diamonds0, diamonds, missiles0, missiles, hammers0, hammers)
	}
	if w, l := walletAndLedger(t, database, id); w != wallet0+6_500_000_000 || l != w {
		t.Fatalf("after the package: wallet %d, ledger %d", w, l)
	}

	b := appleBuy(t, ts.URL, token, "badge_royal_ace_499", sign("14", "badge_royal_ace_499"))
	badge, _ := b.body["badge"].(map[string]any)
	if b.status != http.StatusOK || b.body["credited"] != true || badge == nil || badge["code"] != "ROYAL_ACE" {
		t.Fatalf("badge: %d %v", b.status, b.body)
	}
	var held int
	if err := database.Pool.QueryRow(ctx,
		`SELECT count(*) FROM user_badges WHERE user_id = $1 AND badge_code = 'ROYAL_ACE'`, id).Scan(&held); err != nil || held != 1 {
		t.Fatalf("the badge's grant: %d, %v", held, err)
	}
	// Each soft purchase's guard row is keyed on the App Store's key.
	for table, key := range map[string]string{
		"diamond_purchases": "appstore:11", "hammer_purchases": "appstore:12", "badge_purchases": "appstore:14",
	} {
		var n int
		if err := database.Pool.QueryRow(ctx, `SELECT count(*) FROM `+table+` WHERE purchase_token = $1`, key).Scan(&n); err != nil || n != 1 {
			t.Fatalf("%s row %s: %d, %v", table, key, n, err)
		}
	}
	// Replays of each credit nothing.
	for product, tx := range map[string]string{"diamonds_20_699": "11", "hammers_50_699": "12", "premium_1_9999": "13", "badge_royal_ace_499": "14"} {
		again := appleBuy(t, ts.URL, token, product, sign(tx, product))
		if again.status != http.StatusOK || again.body["credited"] != false {
			t.Fatalf("replayed %s: %d %v", product, again.status, again.body)
		}
	}
	if d2, m2, h2 := softWallets(t, database, id); d2 != diamonds || m2 != missiles || h2 != hammers {
		t.Fatalf("a replay moved a wallet: %d %d %d → %d %d %d", diamonds, missiles, hammers, d2, m2, h2)
	}
}

// What the App Store door refuses, and with what — the codes the app decides
// from whether to finish the transaction (400, 402) or keep it for the next
// session (401, 5xx).
func TestTheAppStoreDoorRefusesWhatAppleDidNotSign(t *testing.T) {
	a, database, signer := newAppleApp(t, nil)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()

	token, id := login(t, ts.URL, "iphone-forger", "Forger")
	wallet0, _ := walletAndLedger(t, database, id)
	forger := appletest.New(t, appletest.Options{})
	good := appletest.Transaction{TransactionID: "31", BundleID: iosBundle, ProductID: "chips_a_99"}

	cases := []struct {
		name, product, transaction string
		status                     int
		code                       string
	}{
		{"a chain under another root", "chips_a_99", forger.Sign(t, good), http.StatusPaymentRequired, "purchase_unverified"},
		{"a cheap pack's transaction for a dear one", "premium_4_29999", signer.Sign(t, good), http.StatusPaymentRequired, "purchase_unverified"},
		{"another app's transaction", "chips_a_99", signer.Sign(t, appletest.Transaction{TransactionID: "32", BundleID: "com.example.other", ProductID: "chips_a_99"}), http.StatusPaymentRequired, "purchase_unverified"},
		{"a refunded transaction", "chips_a_99", signer.Sign(t, appletest.Transaction{TransactionID: "33", BundleID: iosBundle, ProductID: "chips_a_99", RevocationDate: time.Now().UnixMilli()}), http.StatusPaymentRequired, "purchase_unverified"},
		{"a Play token", "chips_a_99", "opaque.play-purchase-token", http.StatusPaymentRequired, "purchase_unverified"},
		{"a product nobody sells", "chips_z_1", signer.Sign(t, appletest.Transaction{TransactionID: "34", BundleID: iosBundle, ProductID: "chips_z_1"}), http.StatusBadRequest, "unknown_product"},
		{"no transaction", "chips_a_99", "", http.StatusBadRequest, "invalid_purchase"},
		{"no product", "", signer.Sign(t, good), http.StatusBadRequest, "invalid_purchase"},
	}
	for _, c := range cases {
		out := appleBuy(t, ts.URL, token, c.product, c.transaction)
		if out.status != c.status || out.body["error"] != c.code {
			t.Errorf("%s: %d %v, want %d %s", c.name, out.status, out.body, c.status, c.code)
		}
	}
	if out := postJSON(ts.URL, "not-a-session", "/api/purchases/apple", map[string]any{"productId": "chips_a_99", "transaction": signer.Sign(t, good)}); out.status != http.StatusUnauthorized {
		t.Errorf("no session: %d %v", out.status, out.body)
	}
	if w, l := walletAndLedger(t, database, id); w != wallet0 || l != wallet0 {
		t.Fatalf("a refused purchase moved chips: %d → %d (ledger %d)", wallet0, w, l)
	}
	// The real thing still sells after all of that.
	if out := appleBuy(t, ts.URL, token, "chips_a_99", signer.Sign(t, good)); out.status != http.StatusOK || out.body["credited"] != true {
		t.Fatalf("the genuine purchase: %d %v", out.status, out.body)
	}
}

// A server that takes Production alone refuses the sandbox — which is why
// the default takes both: App Review buys in the sandbox.
func TestAServerTakingProductionOnlyRefusesASandboxPurchase(t *testing.T) {
	a, _, signer := newAppleApp(t, func(c *config.Config) { c.Apple.IAPEnvironments = []string{"Production"} })
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	token, _ := login(t, ts.URL, "iphone-sandbox-buyer", "Tester")
	jws := signer.Sign(t, appletest.Transaction{TransactionID: "41", BundleID: iosBundle, ProductID: "chips_a_99", Environment: "Sandbox"})
	if out := appleBuy(t, ts.URL, token, "chips_a_99", jws); out.status != http.StatusPaymentRequired {
		t.Fatalf("sandbox on a production-only server: %d %v", out.status, out.body)
	}
}

// With no bundle id the App Store door is shut, as Play's is without
// credentials.
func TestWithNoBundleIDTheAppStoreDoorIsShut(t *testing.T) {
	a, _, signer := newAppleApp(t, func(c *config.Config) { c.Apple.BundleIDs = nil })
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	token, _ := login(t, ts.URL, "iphone-shut-door", "Tester")
	jws := signer.Sign(t, appletest.Transaction{TransactionID: "51", BundleID: iosBundle, ProductID: "chips_a_99"})
	if out := appleBuy(t, ts.URL, token, "chips_a_99", jws); out.status != http.StatusServiceUnavailable || out.body["error"] != "store_unavailable" {
		t.Fatalf("no bundle id: %d %v", out.status, out.body)
	}
}

// A chip pack bought at a table on an iPhone reaches the live seat, as a
// Play pack does: the till is the same one.
func TestAnAppStoreChipPackBoughtAtATableReachesTheSeat(t *testing.T) {
	a, database, signer := newAppleApp(t, nil)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()

	token, id := login(t, ts.URL, "iphone-seated-buyer", "Seated")
	c := dial(t, ts.URL, token)
	mustOK(t, c, socket.EvRoomQuickJoin, map[string]any{"bootAmount": 200, "category": "seen"})
	seat0 := seatOf(t, a, id)
	wallet0, _ := walletAndLedger(t, database, id)

	jws := signer.Sign(t, appletest.Transaction{TransactionID: "61", BundleID: iosBundle, ProductID: "chips_b_199"})
	if out := appleBuy(t, ts.URL, token, "chips_b_199", jws); out.status != http.StatusOK || out.body["credited"] != true {
		t.Fatalf("buy at a table: %d %v", out.status, out.body)
	}
	if seat := seatOf(t, a, id); seat != seat0+52_800_000 {
		t.Fatalf("seat %d → %d, want +52,800,000", seat0, seat)
	}
	if w, l := walletAndLedger(t, database, id); w != wallet0+52_800_000 || l != w {
		t.Fatalf("wallet %d, ledger %d", w, l)
	}
	if out := appleBuy(t, ts.URL, token, "chips_b_199", jws); out.body["credited"] != false || seatOf(t, a, id) != seat0+52_800_000 {
		t.Fatalf("a replay at the table: %v, seat %d", out.body, seatOf(t, a, id))
	}
}

func appleLogin(t *testing.T, baseURL string, body map[string]any) restAnswer {
	t.Helper()
	body["provider"] = "apple"
	out := postJSON(baseURL, "", "/api/auth/login", body)
	if out.err != nil {
		t.Fatalf("login: %v", out.err)
	}
	return out
}

// Sign in with Apple creates an account like any provider's — welcomed, with
// provider "apple" — and signs the same person back into it. (The identity
// token's verification has its own tests in internal/auth; the test config's
// fake providers stand in for Apple here.)
func TestSignInWithAppleCreatesAndReturnsAnAccount(t *testing.T) {
	a, database, _ := newAppleApp(t, nil)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()

	first := appleLogin(t, ts.URL, map[string]any{"providerUserId": "001234.apple-sub", "displayName": "Asha Rao"})
	user, _ := first.body["user"].(map[string]any)
	if first.status != http.StatusOK || first.body["isNew"] != true || user == nil || user["provider"] != "apple" || user["displayName"] != "Asha Rao" {
		t.Fatalf("first Apple login: %d %v", first.status, first.body)
	}
	id, _ := user["id"].(string)
	if w, l := walletAndLedger(t, database, id); w != a.cfg.Game.WelcomeChips || l != w {
		t.Fatalf("the new account's wallet %d, ledger %d", w, l)
	}
	again := appleLogin(t, ts.URL, map[string]any{"providerUserId": "001234.apple-sub"})
	user2, _ := again.body["user"].(map[string]any)
	if again.status != http.StatusOK || again.body["isNew"] != false || user2 == nil || user2["id"] != id || user2["displayName"] != "Asha Rao" {
		t.Fatalf("second Apple login: %d %v", again.status, again.body)
	}
}

// A database built before Sign in with Apple keeps a users.provider CHECK
// that refuses an Apple account. The server notices at boot and answers
// Apple logins 503 — never a 500 at the INSERT — while every other door
// works; once the constraint is replaced by hand and the server restarted,
// Apple signs in.
func TestOnADatabaseFromBeforeItSignInWithAppleIsShutUntilTheCheckIsReplaced(t *testing.T) {
	database := dbtest.Open(t, "app")
	ctx := context.Background()
	for _, stmt := range []string{
		`ALTER TABLE users DROP CONSTRAINT users_provider_check`,
		`ALTER TABLE users ADD CONSTRAINT users_provider_check CHECK (provider IN ('google', 'facebook', 'guest'))`,
	} {
		if _, err := database.Pool.Exec(ctx, stmt); err != nil {
			t.Fatal(err)
		}
	}
	store := livetest.New()
	old := newAppOn(t, testConfig(t, publicDir(t)), database, store)
	ts := httptest.NewServer(old.Handler())
	out := appleLogin(t, ts.URL, map[string]any{"providerUserId": "apple-sub-1", "displayName": "Asha"})
	if out.status != http.StatusServiceUnavailable || out.body["error"] != "provider_unconfigured" {
		t.Fatalf("Apple login on the old CHECK: %d %v", out.status, out.body)
	}
	login(t, ts.URL, "guest-beside-apple", "Guest") // every other door is open
	ts.Close()

	// The hand step from the baseline's header; then a restart (a boot does
	// not put the old CHECK back, nor replace it).
	for _, stmt := range []string{
		`ALTER TABLE users DROP CONSTRAINT users_provider_check`,
		`ALTER TABLE users ADD CONSTRAINT users_provider_check CHECK (provider IN ('google', 'facebook', 'guest', 'apple')) NOT VALID`,
		`ALTER TABLE users VALIDATE CONSTRAINT users_provider_check`,
	} {
		if _, err := database.Pool.Exec(ctx, stmt); err != nil {
			t.Fatal(err)
		}
	}
	fresh := newAppOn(t, testConfig(t, publicDir(t)), database, livetest.New())
	ts2 := httptest.NewServer(fresh.Handler())
	defer ts2.Close()
	out = appleLogin(t, ts2.URL, map[string]any{"providerUserId": "apple-sub-1", "displayName": "Asha"})
	if out.status != http.StatusOK || out.body["isNew"] != true {
		t.Fatalf("Apple login after the hand step: %d %v", out.status, out.body)
	}
}
