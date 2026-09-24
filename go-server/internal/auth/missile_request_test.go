package auth

import (
	"context"
	"log/slog"
	"net/http"
	"testing"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
)

type fakeMissiles struct{ calls int }

func (f *fakeMissiles) TradeMissiles(_ context.Context, _, _, _ string) (*db.MissileTrade, error) {
	f.calls++
	return &db.MissileTrade{Charged: true}, nil
}

// A requestId of the wrong JSON type names ITSELF as the bad field
// (rest-wallet-2, 24 Sep 2026): it used to fail the whole decode, empty packId
// with it, and come back unknown_pack for a pack that exists.
func TestAMissileTradeWithAMistypedRequestIDIsInvalidRequestIDNotUnknownPack(t *testing.T) {
	h := newHarness(t)
	missiles := &fakeMissiles{}
	handler := NewHandler(Deps{
		Config:   h.cfg,
		Users:    h.store,
		Pictures: h.pictures,
		Tokens:   h.tokens,
		Verifier: NewVerifier(h.cfg),
		Missiles: missiles,
		Logger:   slog.New(slog.NewJSONHandler(h.logs, nil)),
	})
	h.mux = http.NewServeMux()
	handler.Register(h.mux)
	token, _ := h.login("device-missile-req-01", "Trader")

	for _, requestID := range []any{12345, map[string]any{"a": 1}, []any{"x"}, true, nil} {
		res := h.do(http.MethodPost, "/api/store/missiles", map[string]any{"packId": "missiles_1", "requestId": requestID}, bearer(token)...)
		if res.status != http.StatusBadRequest || res.body["error"] != CodeInvalidRequestID {
			t.Errorf("requestId %v: %d %s, want 400 %s", requestID, res.status, res.raw, CodeInvalidRequestID)
		}
	}
	// A mistyped packId is still that field's refusal.
	res := h.do(http.MethodPost, "/api/store/missiles", map[string]any{"packId": 1, "requestId": "req-1"}, bearer(token)...)
	if res.status != http.StatusBadRequest || res.body["error"] != CodeUnknownPack {
		t.Errorf("numeric packId: %d %s", res.status, res.raw)
	}
	if missiles.calls != 0 {
		t.Fatalf("a refused trade reached the store %d times", missiles.calls)
	}
	// And a well-formed trade still goes through.
	res = h.do(http.MethodPost, "/api/store/missiles", map[string]any{"packId": "missiles_1", "requestId": "req-1"}, bearer(token)...)
	if res.status != http.StatusOK || missiles.calls != 1 {
		t.Fatalf("a good trade: %d %s (calls %d)", res.status, res.raw, missiles.calls)
	}
}
