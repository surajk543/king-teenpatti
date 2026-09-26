package auth

import (
	"context"
	"log/slog"
	"net/http"
	"strings"
	"testing"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
)

// badgeGateway is a PurchaseGateway that sells the Royal King badge (put on
// Play by an owner: as seeded it is asked for through support).
type badgeGateway struct {
	store *fakeStore
	calls int
}

func (g *badgeGateway) Buy(ctx context.Context, userID, productID, purchaseToken string) (PurchaseOutcome, error) {
	g.calls++
	user, _ := g.store.FindByID(ctx, userID)
	if user != nil {
		zero := 0
		user.Badges = append(user.Badges, db.Badge{Code: "ROYAL_KING", Title: "Royal King", TaxBps: &zero, ExpiresAt: 1_900_000_000_000})
		user.TaxBps = 0
	}
	return PurchaseOutcome{Balance: 200000, Credited: g.calls == 1, User: user,
		Badge: &BoughtBadge{Code: "ROYAL_KING", ExpiresAt: 1_900_000_000_000}}, nil
}

var _ PurchaseGateway = (*badgeGateway)(nil)

// POST /api/purchases/google answers a badge purchase (owner, 27 Sep 2026:
// "Add a icon in Store to buy badges") with the seven keys every purchase
// answers with — all four figures 0 — and an eighth, `badge`: which badge and
// until when. It sells at a table too (a badge is not chips), and is logged
// as a badge.
func TestABadgePurchaseAnswersWithTheBadge(t *testing.T) {
	h := newHarness(t)
	gateway := &badgeGateway{store: h.store}
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

	token, user := h.login("device-badge-0001", "Badge")
	h.seated[user["id"].(string)] = true
	res := h.do(http.MethodPost, "/api/purchases/google",
		map[string]any{"productId": "badge_royal_king_999", "purchaseToken": "badge-receipt-1"}, bearer(token)...)
	if res.status != 200 {
		t.Fatalf("buy: %d %s", res.status, res.raw)
	}
	if len(res.body) != 8 {
		t.Fatalf("the answer has %d keys, want the seven and badge: %s", len(res.body), res.raw)
	}
	badge, _ := res.body["badge"].(map[string]any)
	if badge["code"] != "ROYAL_KING" || badge["expiresAt"] != float64(1_900_000_000_000) || res.body["credited"] != true ||
		res.body["chips"] != float64(0) || res.body["diamonds"] != float64(0) || res.body["hammers"] != float64(0) || res.body["missiles"] != float64(0) {
		t.Fatalf("a badge purchase answers %s", res.raw)
	}
	if u := res.body["user"].(map[string]any); !strings.Contains(string(res.raw), `"code":"ROYAL_KING"`) || u["taxBps"] != float64(0) {
		t.Fatalf("the user in the answer holds the badge at its rate: %s", res.raw)
	}
	if !strings.Contains(h.logs.String(), `"msg":"badge purchased"`) || strings.Contains(h.logs.String(), `"msg":"chips purchased"`) {
		t.Fatalf("a badge purchase is logged as a badge: %s", h.logs.String())
	}
}
