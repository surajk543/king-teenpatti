package auth

import (
	"context"
	"errors"
	"net/http"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
)

// The reward programs over REST (owner, 30 Sep 2026: "a unified REWARD
// PROGRAM system that supports both LOGIN STREAK rewards and CALENDAR
// rewards, with WEEKLY and MONTHLY periods"; 1 Oct 2026: the progression
// types, RESET, SEQUENTIAL and BREAK; db/rewardprograms.go). Two routes, the
// Lucky Draw's shape: a look, allowed anywhere, and a claim, which is the
// lobby's. The server decides what a claim gives, once a day a program,
// whoever asks and however often — so the app never shows a reward twice: it
// celebrates exactly what `granted` says.

// RewardProgramStore is the slice of db.RewardPrograms the endpoints use:
// every running program as it stands for a player, and today's claim of the
// program code names ("" for every one).
type RewardProgramStore interface {
	State(ctx context.Context, userID string) (*db.RewardProgramsView, error)
	Claim(ctx context.Context, userID, code string) (*db.RewardClaimOutcome, error)
}

// rewardClaimRequest is POST /api/reward-programs/claim's body — optional:
// none, or {}, claims every program, as every app before the progression
// types sends; {"programCode": …} claims that one. Nothing else in it is
// read: no day and no reward is ever the client's to choose.
type rewardClaimRequest struct {
	ProgramCode string `json:"programCode"`
}

// RewardPrograms is GET /api/reward-programs (owner, 30 Sep 2026; Go only):
// {serverTime, programs} — every reward program running now, as it stands
// for this player: the program and its current period and the next, today's
// date in its zone, the day the player stands on, whether they can collect
// it, the cycle's status, and every day's reward with its standing and its
// catalogue row. Allowed anywhere, seated included — no wallet moves (it may
// write the player's progress row, user_reward_progress). No store → 503
// reward_programs_unavailable; a server with no program running answers an
// empty list.
func (h *Handler) RewardPrograms(w http.ResponseWriter, r *http.Request, user *db.User) {
	if h.deps.RewardPrograms == nil {
		WriteJSON(w, http.StatusServiceUnavailable, ErrorResponse{Error: CodeRewardProgramsUnavailable, Message: MsgRewardProgramsUnavailable})
		return
	}
	view, err := h.deps.RewardPrograms.State(r.Context(), user.ID)
	if err != nil {
		h.writeError(w, r, err)
		return
	}
	if view.Programs == nil {
		view.Programs = []db.RewardProgramState{}
	}
	WriteJSON(w, http.StatusOK, view)
}

// ClaimRewardPrograms is POST /api/reward-programs/claim (owner, 30 Sep 2026;
// Go only): today's reward of the program the body names, or of every
// running program when it names none — each worked out, granted and recorded
// by the SERVER in a transaction of its own (db.RewardPrograms.Claim),
// answering 200 {serverTime, granted, results, programs, user} — `granted`
// what THIS call gave (empty when today was already claimed, which is the
// answer every later call of the day gets), `results` each program's
// outcome (ALREADY_CLAIMED carries the claim already made: a retry is
// answered with what the first call did), `programs` every program as it now
// stands, `user` the account after.
//
// Order: no store → 503; a body that is not JSON → 400 invalid_json; seated →
// 409 seated; then the claim. A named program refuses with 404
// reward_program_not_found, 409 reward_program_not_running, 409
// reward_cycle_broken or 409 reward_cycle_completed. Lobby-only, and under the
// player's seat lock (Deps.WhileUnseated), for the reasons whileUnseated
// gives: a CHIPS reward moves a wallet, and a seated player's wallet moves
// only at the three checkpoints (CLAUDE.md §5.1).
func (h *Handler) ClaimRewardPrograms(w http.ResponseWriter, r *http.Request, user *db.User) {
	if h.deps.RewardPrograms == nil {
		WriteJSON(w, http.StatusServiceUnavailable, ErrorResponse{Error: CodeRewardProgramsUnavailable, Message: MsgRewardProgramsUnavailable})
		return
	}
	var req rewardClaimRequest
	if err := ReadJSONBody(r, &req); err != nil {
		h.writeError(w, r, err)
		return
	}
	var out *db.RewardClaimOutcome
	var err error
	if !h.whileUnseated(r.Context(), user.ID, func(ctx context.Context) {
		out, err = h.deps.RewardPrograms.Claim(ctx, user.ID, req.ProgramCode)
	}) {
		WriteJSON(w, http.StatusConflict, ErrorResponse{Error: CodeSeated, Message: MsgSeatedRewardPrograms})
		return
	}
	switch {
	case errors.Is(err, db.ErrRewardProgramNotFound):
		WriteJSON(w, http.StatusNotFound, ErrorResponse{Error: CodeRewardProgramNotFound, Message: MsgRewardProgramNotFound})
		return
	case errors.Is(err, db.ErrRewardProgramNotRunning):
		WriteJSON(w, http.StatusConflict, ErrorResponse{Error: CodeRewardProgramNotRunning, Message: MsgRewardProgramNotRunning})
		return
	case errors.Is(err, db.ErrRewardCycleBroken):
		WriteJSON(w, http.StatusConflict, ErrorResponse{Error: CodeRewardCycleBroken, Message: MsgRewardCycleBroken})
		return
	case errors.Is(err, db.ErrRewardCycleCompleted):
		WriteJSON(w, http.StatusConflict, ErrorResponse{Error: CodeRewardCycleCompleted, Message: MsgRewardCycleCompleted})
		return
	case err != nil:
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
