package auth

import (
	"context"
	"log/slog"
	"net/http"
	"reflect"
	"testing"
)

func (u *gatedUsers) DeleteAccount(ctx context.Context, userID string) error {
	u.gate.record(ctx, "delete")
	return u.fakeStore.DeleteAccount(ctx, userID)
}

// DELETE /api/account empties the wallet, so it is a lobby-only wallet change
// like the rest (rest-wallet-1 / LR-1, 24 Sep 2026): it runs under the seat
// lock, so a quickJoin, a switch or an owed settlement can never interleave
// with it, and a player the lock calls seated (or owed) is refused 409 seated
// with nothing erased. Once erased, the player's sessions are ended.
func TestDeletingAnAccountRunsUnderTheSeatLockAndEndsTheSession(t *testing.T) {
	h, gate, _ := newGatedHarness(t)
	var ended []string
	handler := NewHandler(Deps{
		Config:         h.cfg,
		Users:          &gatedUsers{fakeStore: h.store, gate: gate},
		Pictures:       h.pictures,
		Tokens:         h.tokens,
		Verifier:       NewVerifier(h.cfg),
		IsSeated:       func(string) bool { return false },
		WhileUnseated:  gate.whileUnseated,
		AccountDeleted: func(userID string) { ended = append(ended, userID) },
		Logger:         slog.New(slog.NewJSONHandler(h.logs, nil)),
	})
	h.mux = http.NewServeMux()
	handler.Register(h.mux)

	seatedToken, seatedUser := h.login("device-delete-lock-001", "Seated")
	seatedID := seatedUser["id"].(string)
	gate.seat(seatedID)
	res := h.do(http.MethodDelete, "/api/account", nil, bearer(seatedToken)...)
	if res.status != http.StatusConflict || res.body["error"] != CodeSeated {
		t.Fatalf("delete while the lock says seated: %d %s", res.status, res.raw)
	}
	if got := gate.log(); len(got) != 0 {
		t.Fatalf("a refused delete reached the store: %v", got)
	}

	token, user := h.login("device-delete-lock-002", "Lobby")
	id := user["id"].(string)
	res = h.do(http.MethodDelete, "/api/account", nil, bearer(token)...)
	if res.status != http.StatusOK || res.body["deleted"] != true {
		t.Fatalf("delete from the lobby: %d %s", res.status, res.raw)
	}
	if got, want := gate.log(), []string{"delete:locked"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("store calls = %v, want %v", got, want)
	}
	if !reflect.DeepEqual(ended, []string{id}) {
		t.Fatalf("sessions ended = %v, want [%s]", ended, id)
	}
}
