package util

import (
	"io"
	"log/slog"
)

// Log levels accepted by LOG_LEVEL (Node: error | warn | info | debug; default
// info). Anything else falls back to LevelInfo, exactly as Node does.
const (
	LogLevelError = "error"
	LogLevelWarn  = "warn"
	LogLevelInfo  = "info"
	LogLevelDebug = "debug"
)

// ParseLogLevel maps a LOG_LEVEL string onto a slog.Level. Unknown values
// (including "") return slog.LevelInfo, mirroring Node's `?? LEVELS.info`.
func ParseLogLevel(level string) slog.Level {
	switch level {
	case LogLevelError:
		return slog.LevelError
	case LogLevelWarn:
		return slog.LevelWarn
	case LogLevelDebug:
		return slog.LevelDebug
	default:
		return slog.LevelInfo
	}
}

// NewLogger builds the process logger: JSON lines to `w` (stdout in
// production; Node wrote errors to stderr and everything else to stdout — the
// Go port writes every level to one writer, which is a deliberate, recorded
// deviation in PORT_PLAN.md §Logging).
//
// Line shape is slog's default (`time`, `level`, `msg`, then attributes) rather
// than Node's `{t, level, msg, meta:{…}}`. Logs are not part of the wire
// contract, so this is allowed to differ; keep attribute names identical to
// Node's `meta` keys (roomId, userId, code, bootAmount, category, isPrivate,
// maxPot, reason, error, …) so log searches keep working.
//
// Rules for every caller (PORT_PLAN.md §Conventions):
//   - structured attributes only, never fmt.Sprintf'd into the message;
//   - the Table never logs — it emits events and RoomManager logs them;
//   - never log a JWT, a password or a full DATABASE_URL (see db.Redact).
func NewLogger(level string, w io.Writer) *slog.Logger {
	return slog.New(slog.NewJSONHandler(w, &slog.HandlerOptions{Level: ParseLogLevel(level)}))
}
