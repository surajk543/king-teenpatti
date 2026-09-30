package auth

import (
	"context"
	"net/http"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
)

// The reward programs over REST (owner, 30 Sep 2026: "a unified REWARD
// PROGRAM system that supports both LOGIN STREAK rewards and CALENDAR
// rewards, with WEEKLY and MONTHLY periods"; db/rewardprograms.go). Two
// routes, the Lucky Draw's shape: a look, allowed anywhere, and a claim,
// which is the lobby's. The app claims whenever its lobby appears and at
// every session:ready in the lobby; the server decides what a claim gives,
// once a day a program, whoever asks and however often — so the app never
// shows a reward twice: it celebrates exactly what `granted` says.

// RewardProgramStore is the slice of db.RewardPrograms the endpoints use:
// every running program as it stands for a player, and today's claim of
// each.
type RewardProgramStore interface {
	State(ctx context.Context, userID string) ([]db.RewardProgramState, error)
	Claim(ctx context.Context, userID string) (*db.RewardClaimOutcome, error)
}

// RewardProgramsResponse is GET /api/reward-programs: {programs}, every
// running program in sort_order as it stands for the caller.
type RewardProgramsResponse struct {
	Programs []db.RewardProgramState `json:"programs"`
}

// RewardPrograms is GET /api/reward-programs (owner, 30 Sep 2026; Go only):
// every reward program running now, as it stands for this player — the
// program and its current period, today's date in its zone, the day the
// player stands on (a login streak's consecutive day, a calendar's date),
// whether today is claimed, and every day's reward with its catalogue row.
// Allowed anywhere, seated included — it only reads. No store → 503
// reward_programs_unavailable; a server with no program running answers an
// empty list.
func (h *Handler) RewardPrograms(w http.ResponseWriter, r *http.Request, user *db.User) {
	if h.deps.RewardPrograms == nil {
		WriteJSON(w, http.StatusServiceUnavailable, ErrorResponse{Error: CodeRewardProgramsUnavailable, Message: MsgRewardProgramsUnavailable})
		return
	}
	states, err := h.deps.RewardPrograms.State(r.Context(), user.ID)
	if err != nil {
		h.writeError(w, r, err)
		return
	}
	if states == nil {
		states = []db.RewardProgramState{}
	}
	WriteJSON(w, http.StatusOK, RewardProgramsResponse{Programs: states})
}

// ClaimRewardPrograms is POST /api/reward-programs/claim (owner, 30 Sep 2026;
// Go only): today's reward of every running program, each worked out,
// granted and recorded by the SERVER in a transaction of its own
// (db.RewardPrograms.Claim), answering 200 {granted, programs, user} —
// `granted` what THIS call gave (empty when every program's today was
// already claimed, which is the answer every later call of the day gets),
// `programs` every program as it now stands, `user` the account after. The
// body is not read: nothing a client sends decides a day or a reward.
//
// Order: no store → 503; seated → 409 seated; then the claim. Lobby-only,
// and under the player's seat lock (Deps.WhileUnseated), for the reasons
// whileUnseated gives: a CHIPS reward moves a wallet, and a seated player's
// wallet moves only at the three checkpoints (CLAUDE.md §5.1).
func (h *Handler) ClaimRewardPrograms(w http.ResponseWriter, r *http.Request, user *db.User) {
	if h.deps.RewardPrograms == nil {
		WriteJSON(w, http.StatusServiceUnavailable, ErrorResponse{Error: CodeRewardProgramsUnavailable, Message: MsgRewardProgramsUnavailable})
		return
	}
	var out *db.RewardClaimOutcome
	var err error
	if !h.whileUnseated(r.Context(), user.ID, func(ctx context.Context) {
		out, err = h.deps.RewardPrograms.Claim(ctx, user.ID)
	}) {
		WriteJSON(w, http.StatusConflict, ErrorResponse{Error: CodeSeated, Message: MsgSeatedRewardPrograms})
		return
	}
	if err != nil {
		h.writeError(w, r, err)
		return
	}
	if h.deps.Logger != nil {
		for _, g := range out.Granted {
			h.deps.Logger.Info("reward claimed",
				"userId", user.ID, "program", g.ProgramCode, "day", g.Day, "rewardType", g.RewardType,
				"alreadyOwned", g.AlreadyOwned)
		}
	}
	WriteJSON(w, http.StatusOK, out)
}
