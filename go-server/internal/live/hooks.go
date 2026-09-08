package live

import (
	"context"
	"time"
)

// Hooks receives one Observe call per Store operation: op is the snake_case
// method name ("save_table", "take_resume_offer", …), err the call's result
// as returned to the caller — ErrNotFound (a miss) and ErrStale (fencing)
// included, so the observer should classify with errors.Is rather than
// treating every non-nil as a failure — and d its wall-clock duration. The
// app feeds Prometheus from here (game_live_store_operations_total,
// game_live_store_duration_seconds, game_live_store_errors_total); this
// package never imports prometheus itself.
type Hooks struct {
	Observe func(op string, err error, d time.Duration)
}

// WithHooks decorates s so every call is timed and reported to h. A nil
// Observe returns s itself. Kind is not observed (no I/O).
func WithHooks(s Store, h Hooks) Store {
	if h.Observe == nil {
		return s
	}
	return &hooked{Store: s, observe: h.Observe}
}

type hooked struct {
	Store
	observe func(op string, err error, d time.Duration)
}

// Unwrap returns the decorated Store.
func (h *hooked) Unwrap() Store { return h.Store }

func (h *hooked) SaveTable(ctx context.Context, roomID string, seq int64, snapshot []byte, ttl time.Duration) (err error) {
	start := time.Now()
	defer func() { h.observe("save_table", err, time.Since(start)) }()
	err = h.Store.SaveTable(ctx, roomID, seq, snapshot, ttl)
	return err
}

func (h *hooked) LoadTable(ctx context.Context, roomID string) (seq int64, snapshot []byte, err error) {
	start := time.Now()
	defer func() { h.observe("load_table", err, time.Since(start)) }()
	seq, snapshot, err = h.Store.LoadTable(ctx, roomID)
	return seq, snapshot, err
}

func (h *hooked) DeleteTable(ctx context.Context, roomID string) (err error) {
	start := time.Now()
	defer func() { h.observe("delete_table", err, time.Since(start)) }()
	err = h.Store.DeleteTable(ctx, roomID)
	return err
}

func (h *hooked) ListTables(ctx context.Context) (refs []TableRef, err error) {
	start := time.Now()
	defer func() { h.observe("list_tables", err, time.Since(start)) }()
	refs, err = h.Store.ListTables(ctx)
	return refs, err
}

func (h *hooked) AppendChat(ctx context.Context, roomID string, message []byte, max int) (err error) {
	start := time.Now()
	defer func() { h.observe("append_chat", err, time.Since(start)) }()
	err = h.Store.AppendChat(ctx, roomID, message, max)
	return err
}

func (h *hooked) LoadChat(ctx context.Context, roomID string) (msgs [][]byte, err error) {
	start := time.Now()
	defer func() { h.observe("load_chat", err, time.Since(start)) }()
	msgs, err = h.Store.LoadChat(ctx, roomID)
	return msgs, err
}

func (h *hooked) DeleteChat(ctx context.Context, roomID string) (err error) {
	start := time.Now()
	defer func() { h.observe("delete_chat", err, time.Since(start)) }()
	err = h.Store.DeleteChat(ctx, roomID)
	return err
}

func (h *hooked) SetSeated(ctx context.Context, userID, roomID string) (err error) {
	start := time.Now()
	defer func() { h.observe("set_seated", err, time.Since(start)) }()
	err = h.Store.SetSeated(ctx, userID, roomID)
	return err
}

func (h *hooked) ClearSeated(ctx context.Context, userID string) (err error) {
	start := time.Now()
	defer func() { h.observe("clear_seated", err, time.Since(start)) }()
	err = h.Store.ClearSeated(ctx, userID)
	return err
}

func (h *hooked) SeatOf(ctx context.Context, userID string) (roomID string, err error) {
	start := time.Now()
	defer func() { h.observe("seat_of", err, time.Since(start)) }()
	roomID, err = h.Store.SeatOf(ctx, userID)
	return roomID, err
}

func (h *hooked) SetOnline(ctx context.Context, userID, instance string, ttl time.Duration) (err error) {
	start := time.Now()
	defer func() { h.observe("set_online", err, time.Since(start)) }()
	err = h.Store.SetOnline(ctx, userID, instance, ttl)
	return err
}

func (h *hooked) SetOffline(ctx context.Context, userID string) (err error) {
	start := time.Now()
	defer func() { h.observe("set_offline", err, time.Since(start)) }()
	err = h.Store.SetOffline(ctx, userID)
	return err
}

func (h *hooked) OnlineCount(ctx context.Context) (n int, err error) {
	start := time.Now()
	defer func() { h.observe("online_count", err, time.Since(start)) }()
	n, err = h.Store.OnlineCount(ctx)
	return n, err
}

func (h *hooked) PutResumeOffer(ctx context.Context, userID string, offer ResumeOffer, ttl time.Duration) (err error) {
	start := time.Now()
	defer func() { h.observe("put_resume_offer", err, time.Since(start)) }()
	err = h.Store.PutResumeOffer(ctx, userID, offer, ttl)
	return err
}

func (h *hooked) TakeResumeOffer(ctx context.Context, userID string) (offer ResumeOffer, err error) {
	start := time.Now()
	defer func() { h.observe("take_resume_offer", err, time.Since(start)) }()
	offer, err = h.Store.TakeResumeOffer(ctx, userID)
	return offer, err
}

func (h *hooked) DeleteResumeOffer(ctx context.Context, userID string) (err error) {
	start := time.Now()
	defer func() { h.observe("delete_resume_offer", err, time.Since(start)) }()
	err = h.Store.DeleteResumeOffer(ctx, userID)
	return err
}

func (h *hooked) PublishTable(ctx context.Context, t TableSummary) (err error) {
	start := time.Now()
	defer func() { h.observe("publish_table", err, time.Since(start)) }()
	err = h.Store.PublishTable(ctx, t)
	return err
}

func (h *hooked) RetireTable(ctx context.Context, roomID, category string, bootAmount int64) (err error) {
	start := time.Now()
	defer func() { h.observe("retire_table", err, time.Since(start)) }()
	err = h.Store.RetireTable(ctx, roomID, category, bootAmount)
	return err
}

func (h *hooked) Candidates(ctx context.Context, category string, bootAmount int64) (out []TableSummary, err error) {
	start := time.Now()
	defer func() { h.observe("candidates", err, time.Since(start)) }()
	out, err = h.Store.Candidates(ctx, category, bootAmount)
	return out, err
}

func (h *hooked) Ping(ctx context.Context) (err error) {
	start := time.Now()
	defer func() { h.observe("ping", err, time.Since(start)) }()
	err = h.Store.Ping(ctx)
	return err
}

func (h *hooked) Close() (err error) {
	start := time.Now()
	defer func() { h.observe("close", err, time.Since(start)) }()
	err = h.Store.Close()
	return err
}
