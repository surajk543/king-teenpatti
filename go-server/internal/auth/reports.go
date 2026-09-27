package auth

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// Report Player (owner, 27 Sep 2026: "A player sitting at a gameplay table
// must be able to report another player currently at the same table"; Go
// only). ONE route:
//
//	POST /api/reports {reportedUserId, reason, description?} → ReportPlayer (201)
//
// REST, like Friends at the table: a report is a persistent account action a
// seated player makes from the table's player drawer, and it must never pass
// through the table's actor — a report changes nothing in the game. It is
// signed in (RequireAuth), limited per client IP with the other writes (the
// wallet limiter) and per account (Handler.reportAttempts), and answered with
// the brief's {success, message} and nothing more: never the report's id, its
// status, the table, the hand, or anything moderation decides.
//
// and, beside it, the reporter's own standing against the limit (owner, 27
// Sep 2026: "if user has reported 2 player, then reporting by him should be
// disabled in UI, and show a cool down time in UI when can he report again"):
//
//	GET  /api/reports/limit → ReportLimit (200 {limit})
//
// read when the app opens a player's drawer, and carried on every answer that
// changes it — a report filed (201) and one refused for the limit (429) — so
// the drawer switches its Report line off, and counts down to the moment it
// opens again, from the server's own count. It names nothing but the caller's
// own figures: no report, no player reported, no table.
//
// SERVER AUTHORITY. The body is three fields and nothing else is read: the
// reporter is the session's account; the table, its game, category and
// variant, and the hand are the server's own (Deps.ReportContext: the room the
// two share now, or shared within REPORT_RECENT_MS); the timestamps and the
// status are the database's. A client sending tableId, handId, status,
// createdAt or reporterUserId has them ignored.

// ReportReasons is every reason a report may give, in the order the app lists
// them (the brief's). Matched exactly — no trimming, no case folding — as the
// variations are. OTHER needs a description; the rest take one optionally.
// A new reason is a value here and in the app; player_reports.reason is
// deliberately not a CHECK (V1.0.0's PLAYER REPORTS).
var ReportReasons = []string{
	"CHEATING",
	"HARASSMENT",
	"ABUSIVE_LANGUAGE",
	"SPAM",
	"INAPPROPRIATE_BEHAVIOR",
	"SUSPICIOUS_GAMEPLAY",
	"COLLUSION",
	"EXPLOITING_BUG",
	ReportReasonOther,
}

// ReportReasonOther is the reason that must say what happened.
const ReportReasonOther = "OTHER"

// The report route's answer and refusals, worded for the player. None of
// them says anything about a report already filed, a moderation decision or
// an investigation.
const (
	MsgReportSubmitted            = "Report submitted successfully."
	MsgInvalidReportReason        = "Choose a reason for the report."
	MsgReportDescriptionRequired  = "Describe what happened."
	MsgReportDescriptionTooLongFm = "Keep the description to %d characters or fewer."
	MsgSelfReport                 = "You cannot report yourself."
	MsgPlayerNotAtTable           = "You can only report a player you are playing with."
	MsgAlreadyReported            = "You have already reported this player."
	MsgReportLimitReached         = "You have reached the report limit. Try again later."
)

// ReportStore is the slice of db.Reports the report routes use.
type ReportStore interface {
	Submit(ctx context.Context, report db.PlayerReport, limits db.ReportLimits) (int64, error)
	Quota(ctx context.Context, reporterID string, limits db.ReportLimits) (db.ReportQuota, error)
}

// ReportPlayerBody ← POST /api/reports {reportedUserId, reason, description}:
// the only three things a client says about a report. Each field is read on
// its own, as SendFriendRequestBody reads userId: a value of the wrong JSON
// type reads as "", which the handler refuses under that field's own code.
// Every other key — a table, a hand, a status, a timestamp, a reporter — is
// ignored.
type ReportPlayerBody struct {
	ReportedUserID string `json:"reportedUserId"`
	Reason         string `json:"reason"`
	Description    string `json:"description"`
}

// UnmarshalJSON applies the rule documented on ReportPlayerBody.
func (b *ReportPlayerBody) UnmarshalJSON(data []byte) error {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	*b = ReportPlayerBody{}
	text := func(key string) string {
		var v string
		if r, ok := raw[key]; ok && json.Unmarshal(r, &v) == nil {
			return v
		}
		return ""
	}
	b.ReportedUserID = text("reportedUserId")
	b.Reason = text("reason")
	b.Description = text("description")
	return nil
}

// ReportSubmitted ← POST /api/reports (201): the brief's answer, and the
// reporter's standing after it (Limit; absent when the store could not say —
// the report is filed either way).
type ReportSubmitted struct {
	Success bool             `json:"success"`
	Message string           `json:"message"`
	Limit   *ReportLimitView `json:"limit,omitempty"`
}

// ReportLimitView is a reporter's standing against the report limit, as the
// app reads it (db.ReportQuota): {max, used, remaining, windowMs, availableAt,
// waitMs}. max 0 = no limit. availableAt (epoch ms, the server's clock) and
// waitMs (how long from this answer) say when the next report is accepted
// while remaining is 0, and are 0 otherwise; the app counts down from waitMs,
// so a phone whose clock is wrong still counts to the server's moment.
type ReportLimitView struct {
	Max         int   `json:"max"`
	Used        int   `json:"used"`
	Remaining   int   `json:"remaining"`
	WindowMs    int64 `json:"windowMs"`
	AvailableAt int64 `json:"availableAt"`
	WaitMs      int64 `json:"waitMs"`
}

// reportLimitView is q on the wire.
func reportLimitView(q db.ReportQuota) *ReportLimitView {
	v := &ReportLimitView{Max: q.Max, Used: q.Used, Remaining: q.Remaining, WindowMs: q.Window.Milliseconds()}
	if q.Limited() {
		v.AvailableAt = q.AvailableAt
		v.WaitMs = max(q.AvailableAt-q.Now, 0)
	}
	return v
}

// limitedQuota is the standing a limit refusal reports: the store's own
// (db.ReportLimitReached.Quota), or — for a refusal that carries only the
// moment it lifts — every report of the limit used until RetryAt, counted
// from this process's clock.
func limitedQuota(limited *db.ReportLimitReached, limits db.ReportLimits) db.ReportQuota {
	q := limited.Quota
	if q.Max == 0 {
		q = db.ReportQuota{Max: max(limits.MaxPerReporter, 1), Window: limits.Window}
		q.Used = q.Max
	}
	if q.AvailableAt == 0 {
		q.AvailableAt = limited.RetryAt
	}
	if q.Now == 0 {
		q.Now = time.Now().UnixMilli()
	}
	q.Remaining = 0
	return q
}

// ReportLimitAnswer ← GET /api/reports/limit.
type ReportLimitAnswer struct {
	Limit *ReportLimitView `json:"limit"`
}

// reportLimitRefusal ← POST /api/reports (429 report_limit_reached): the
// refusal, and the standing that caused it.
type reportLimitRefusal struct {
	Error   string           `json:"error"`
	Message string           `json:"message"`
	Limit   *ReportLimitView `json:"limit"`
}

// ReportPlayer is POST /api/reports: the caller reports a player they share a
// table with, or shared one with moments ago. Refusals, in order:
//
//	429 rate_limited           more than REPORT_ATTEMPT_LIMIT requests from this account in the window (Retry-After)
//	400 invalid_json           the body
//	400 invalid_player_id      reportedUserId empty once trimmed, or over 64 characters
//	400 self_report            the caller's own id
//	400 invalid_report_reason  a reason not in ReportReasons
//	400 description_required   OTHER with no description
//	400 description_too_long   over REPORT_DESCRIPTION_MAX characters
//	409 player_not_at_table    not at the caller's table, nor at a table they shared within REPORT_RECENT_MS
//	404 player_not_found       the account no longer exists (deleted since)
//	409 already_reported       this player, by this caller, for this hand or within REPORT_PAIR_WINDOW_MS
//	429 report_limit_reached   REPORT_MAX_PER_REPORTER reports filed within REPORT_WINDOW_MS (Retry-After)
//	500 internal_error         the database failed; nothing was filed
//
// and before all of them RequireAuth's 401/403. Whether the player exists is
// looked at only once they are known to have shared a table with the caller,
// so a guessed id tells nobody whether it names an account.
func (h *Handler) ReportPlayer(w http.ResponseWriter, r *http.Request, user *db.User) {
	if ok, wait, first := h.reportAttempts.allow(user.ID); !ok {
		if first && h.deps.Logger != nil {
			h.deps.Logger.Warn("report attempts limited", "userId", user.ID)
		}
		w.Header().Set("Retry-After", retryAfterSeconds(wait))
		WriteJSON(w, http.StatusTooManyRequests, ErrorResponse{Error: CodeRateLimited, Message: MsgRateLimited})
		return
	}
	var body ReportPlayerBody
	if err := ReadJSONBody(r, &body); err != nil {
		h.writeError(w, r, err)
		return
	}
	reportedID, ok := playerIDFrom(body.ReportedUserID)
	if !ok {
		refuseReport(w, http.StatusBadRequest, CodeInvalidPlayerID, MsgInvalidPlayerID)
		return
	}
	if reportedID == user.ID {
		refuseReport(w, http.StatusBadRequest, CodeSelfReport, MsgSelfReport)
		return
	}
	if !slices.Contains(ReportReasons, body.Reason) {
		refuseReport(w, http.StatusBadRequest, CodeInvalidReportReason, MsgInvalidReportReason)
		return
	}
	limits := h.reportConfig()
	description := NormalizeReportDescription(body.Description)
	if description == "" && body.Reason == ReportReasonOther {
		refuseReport(w, http.StatusBadRequest, CodeDescriptionRequired, MsgReportDescriptionRequired)
		return
	}
	if utf8.RuneCountInString(description) > limits.DescriptionMax {
		refuseReport(w, http.StatusBadRequest, CodeDescriptionTooLong, fmt.Sprintf(MsgReportDescriptionTooLongFm, limits.DescriptionMax))
		return
	}
	var where game.ReportContext
	associated := false
	if h.deps.ReportContext != nil {
		where, associated = h.deps.ReportContext(user.ID, reportedID)
	}
	if !associated {
		refuseReport(w, http.StatusConflict, CodePlayerNotAtTable, MsgPlayerNotAtTable)
		return
	}
	dbLimits := db.ReportLimits{
		MaxPerReporter: limits.MaxPerReporter,
		Window:         limits.Window,
		PairWindow:     limits.PairWindow,
	}
	id, err := h.deps.Reports.Submit(r.Context(), db.PlayerReport{
		ReporterID:  user.ID,
		ReportedID:  reportedID,
		Reason:      body.Reason,
		Description: description,
		Game:        string(where.Game),
		Category:    string(where.Category),
		Variant:     where.Variant,
		TableID:     where.RoomID,
		HandID:      where.HandID,
	}, dbLimits)
	var limited *db.ReportLimitReached
	switch {
	case errors.Is(err, db.ErrReportedNotFound):
		refuseReport(w, http.StatusNotFound, CodePlayerNotFound, MsgPlayerNotFound)
	case errors.Is(err, db.ErrSelfReport):
		refuseReport(w, http.StatusBadRequest, CodeSelfReport, MsgSelfReport)
	case errors.Is(err, db.ErrAlreadyReported):
		refuseReport(w, http.StatusConflict, CodeAlreadyReported, MsgAlreadyReported)
	case errors.As(err, &limited):
		quota := limitedQuota(limited, dbLimits)
		w.Header().Set("Retry-After", retryAfterSeconds(time.Duration(max(quota.AvailableAt-quota.Now, 0))*time.Millisecond))
		WriteJSON(w, http.StatusTooManyRequests, reportLimitRefusal{
			Error: CodeReportLimitReached, Message: MsgReportLimitReached, Limit: reportLimitView(quota),
		})
	case err != nil:
		h.writeError(w, r, err)
	default:
		if h.deps.Logger != nil {
			h.deps.Logger.Info("player report filed", "reportId", id, "reason", body.Reason,
				"game", string(where.Game), "category", string(where.Category))
		}
		answer := ReportSubmitted{Success: true, Message: MsgReportSubmitted}
		if quota, err := h.deps.Reports.Quota(r.Context(), user.ID, dbLimits); err == nil {
			answer.Limit = reportLimitView(quota)
		} else if h.deps.Logger != nil {
			h.deps.Logger.Warn("report limit not read after a report", "userId", user.ID, "err", err.Error())
		}
		WriteJSON(w, http.StatusCreated, answer)
	}
}

// ReportLimit is GET /api/reports/limit: the caller's standing against the
// report limit — how many reports they have filed within the window, how many
// more it allows, and when the next opens when none do. Signed in; it reads
// the caller's own rows and nothing else, and is not counted against the
// report attempts (opening a drawer is not a report). 500 internal_error when
// the database fails.
func (h *Handler) ReportLimit(w http.ResponseWriter, r *http.Request, user *db.User) {
	limits := h.reportConfig()
	quota, err := h.deps.Reports.Quota(r.Context(), user.ID, db.ReportLimits{
		MaxPerReporter: limits.MaxPerReporter,
		Window:         limits.Window,
		PairWindow:     limits.PairWindow,
	})
	if err != nil {
		h.writeError(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, ReportLimitAnswer{Limit: reportLimitView(quota)})
}

// reportConfig is the configured limits, or config.Defaults()' where the
// handler was built without a config (unit tests).
func (h *Handler) reportConfig() reportLimits {
	if h.deps.Config == nil {
		return reportLimits{MaxPerReporter: 2, Window: 24 * time.Hour, PairWindow: 24 * time.Hour, DescriptionMax: 500}
	}
	rc := h.deps.Config.Reports
	return reportLimits{MaxPerReporter: rc.MaxPerReporter, Window: rc.Window, PairWindow: rc.PairWindow, DescriptionMax: rc.DescriptionMax}
}

type reportLimits struct {
	MaxPerReporter int
	Window         time.Duration
	PairWindow     time.Duration
	DescriptionMax int
}

// NormalizeReportDescription is a description as it is stored: line breaks
// kept (a CR LF or a lone CR as LF), every other control character, and every
// format character (a bidi override, a zero-width joiner standing alone),
// turned into a space, and the whole trimmed. "" when nothing is left.
func NormalizeReportDescription(raw string) string {
	raw = strings.ReplaceAll(raw, "\r\n", "\n")
	var b strings.Builder
	b.Grow(len(raw))
	for _, r := range raw {
		switch {
		case r == '\n' || r == '\r':
			b.WriteByte('\n')
		case unicode.IsControl(r) || (unicode.Is(unicode.Cf, r) && r != 0x200D):
			b.WriteByte(' ')
		default:
			b.WriteRune(r)
		}
	}
	return strings.TrimFunc(b.String(), unicode.IsSpace)
}

// retryAfterSeconds is a Retry-After value: whole seconds, rounded up, at
// least 1.
func retryAfterSeconds(wait time.Duration) string {
	secs := int((wait + time.Second - 1) / time.Second)
	if secs < 1 {
		secs = 1
	}
	return strconv.Itoa(secs)
}

// refuseReport writes a report refusal: {error, message}.
func refuseReport(w http.ResponseWriter, status int, code, message string) {
	WriteJSON(w, status, ErrorResponse{Error: code, Message: message})
}
