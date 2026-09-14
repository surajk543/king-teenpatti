package auth

import (
	"context"
	"log/slog"
	"net/http"
	"strings"
	"testing"
)

// premiumGateway is a PurchaseGateway that sells premium_1_9999 (650 Crore,
// 1 missile, 10 hammers) and credits it on the first call only.
type premiumGateway struct {
	store *fakeStore
	calls int
}

func (g *premiumGateway) Buy(ctx context.Context, userID, productID, purchaseToken string) (PurchaseOutcome, error) {
	g.calls++
	// FindByID hands out a copy, so the credit goes on the stored row.
	if stored := g.store.users[userID]; stored != nil && g.calls == 1 {
		stored.Chips += 6_500_000_000
		stored.Missile++
		stored.Hammer += 10
	}
	user, _ := g.store.FindByID(ctx, userID)
	balance := int64(0)
	if user != nil {
		balance = user.Chips
	}
	return PurchaseOutcome{Chips: 6_500_000_000, Missiles: 1, Hammers: 10, Balance: balance, Credited: g.calls == 1, User: user}, nil
}

var _ PurchaseGateway = (*premiumGateway)(nil)

// POST /api/purchases/google answers a premium package with its chips,
// missiles and hammers — all non-zero, diamonds 0 — in the answer's seven
// keys, the user holding all three; logs it as chips with the missiles and
// hammers beside them, never as a hammer pack; and sells it at a table. A
// replay answers the same figures with credited false and is not logged.
func TestAPremiumPackageAnswersWithItsChipsMissilesAndHammers(t *testing.T) {
	h := newHarness(t)
	gateway := &premiumGateway{store: h.store}
	h.mux = http.NewServeMux()
	NewHandler(Deps{
		Config:    h.cfg,
		Users:     h.store,
		Pictures:  h.pictures,
		Tokens:    h.tokens,
		Verifier:  NewVerifier(h.cfg),
		IsSeated:  func(id string) bool { return h.seated[id] },
		Purchases: gateway,
		Logger:    slog.New(slog.NewJSONHandler(h.logs, nil)),
	}).Register(h.mux)
	h.mux.Handle("/api/", NotFoundHandler())

	token, user := h.login("device-premium-0001", "Premium")
	h.seated[user["id"].(string)] = true
	buy := func() response {
		t.Helper()
		res := h.do(http.MethodPost, "/api/purchases/google",
			map[string]any{"productId": "premium_1_9999", "purchaseToken": "premium-receipt-1"}, bearer(token)...)
		if res.status != 200 {
			t.Fatalf("buy: %d %s", res.status, res.raw)
		}
		if len(res.body) != 7 {
			t.Fatalf("the answer has %d keys, want 7: %s", len(res.body), res.raw)
		}
		if res.body["chips"] != float64(6_500_000_000) || res.body["missiles"] != float64(1) || res.body["hammers"] != float64(10) || res.body["diamonds"] != float64(0) {
			t.Fatalf("a premium package answers %s", res.raw)
		}
		return res
	}

	res := buy()
	t.Logf("premium package answer: %s", res.raw)
	if res.body["credited"] != true || res.body["balance"] != float64(200000+6_500_000_000) {
		t.Fatalf("first buy: %s", res.raw)
	}
	if u := res.body["user"].(map[string]any); u["chips"] != float64(200000+6_500_000_000) || u["missile"] != float64(1) || u["hammer"] != float64(10) {
		t.Fatalf("the user in the answer holds the package: %s", res.raw)
	}
	logs := h.logs.String()
	if !strings.Contains(logs, `"msg":"chips purchased"`) || !strings.Contains(logs, `"chips":6500000000,"missiles":1,"hammers":10`) ||
		strings.Contains(logs, `"msg":"hammers purchased"`) {
		t.Fatalf("a premium package is logged as chips with its missiles and hammers: %s", logs)
	}

	again := buy()
	if again.body["credited"] != false {
		t.Fatalf("replay: %s", again.raw)
	}
	if u := again.body["user"].(map[string]any); u["missile"] != float64(1) || u["hammer"] != float64(10) {
		t.Fatalf("a replay moved a wallet: %s", again.raw)
	}
	if strings.Count(h.logs.String(), `"msg":"chips purchased"`) != 1 {
		t.Fatalf("a replay was logged as a purchase: %s", h.logs.String())
	}
}
