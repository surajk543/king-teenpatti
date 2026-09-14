package auth

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"strings"
	"testing"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
)

// hammerGateway is a PurchaseGateway that sells one hammer pack.
type hammerGateway struct {
	store *fakeStore
	calls int
}

func (g *hammerGateway) Buy(ctx context.Context, userID, productID, purchaseToken string) (PurchaseOutcome, error) {
	g.calls++
	user, _ := g.store.FindByID(ctx, userID)
	if user != nil {
		user.Hammer += 50
	}
	return PurchaseOutcome{Hammers: 50, Balance: 200000, Credited: g.calls == 1, User: user}, nil
}

var _ PurchaseGateway = (*hammerGateway)(nil)

// POST /api/purchases/google answers a hammer pack with the hammers it
// credited beside chips, diamonds and missiles — all four keys, one of them
// non-zero — and logs it as hammers, not chips.
func TestAHammerPackAnswersWithItsHammers(t *testing.T) {
	h := newHarness(t)
	gateway := &hammerGateway{store: h.store}
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

	token, user := h.login("device-hammer-0001", "Hammer")
	if user["hammer"] != float64(0) {
		// The fake store makes accounts with no hammers; the real default of
		// 20 is the database's (users.hammer's default) and is tested there.
		t.Fatalf("fake account hammers %v", user["hammer"])
	}
	// Seated or not, a hammer pack sells: hammers are not chips.
	h.seated[user["id"].(string)] = true

	res := h.do(http.MethodPost, "/api/purchases/google",
		map[string]any{"productId": "hammers_50_699", "purchaseToken": "hammer-receipt-1"}, bearer(token)...)
	if res.status != 200 {
		t.Fatalf("buy: %d %s", res.status, res.raw)
	}
	for _, key := range []string{"credited", "chips", "diamonds", "hammers", "missiles", "balance", "user"} {
		if _, ok := res.body[key]; !ok {
			t.Fatalf("the answer lacks %q: %s", key, res.raw)
		}
	}
	if len(res.body) != 7 {
		t.Fatalf("the answer has %d keys, want 7: %s", len(res.body), res.raw)
	}
	if res.body["hammers"] != float64(50) || res.body["chips"] != float64(0) || res.body["diamonds"] != float64(0) || res.body["missiles"] != float64(0) || res.body["credited"] != true {
		t.Fatalf("a hammer pack answers %s", res.raw)
	}
	if u := res.body["user"].(map[string]any); u["hammer"] != float64(50) {
		t.Fatalf("the user in the answer carries its hammers: %s", res.raw)
	}
	if !strings.Contains(h.logs.String(), `"msg":"hammers purchased"`) || strings.Contains(h.logs.String(), `"msg":"chips purchased"`) {
		t.Fatalf("a hammer pack is logged as hammers: %s", h.logs.String())
	}
}

// The public user carries hammer beside diamond (json "hammer").
func TestThePublicUserCarriesItsHammers(t *testing.T) {
	raw, err := json.Marshal(&db.User{ID: "u", Diamond: 1, Hammer: 20})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), `"diamond":1,"hammer":20,`) {
		t.Fatalf("user JSON %s", raw)
	}
}
