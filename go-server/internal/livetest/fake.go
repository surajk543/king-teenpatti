// Package livetest is a small in-memory live.Store for the socket and app
// test suites (PORT_PLAN.md §Testing): deliberately independent of
// live.Memory so those suites do not move when the store implementation does.
// It keeps the contract's semantics that the platform layer relies on — ttl
// expiry from an injectable clock, take-once resume offers, CAS on the table
// seq — and adds what a test wants to assert: per-operation call counts, a
// peek at presence and offers without consuming them, and injectable
// failures per operation.
package livetest

import (
	"context"
	"sort"
	"sync"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/live"
)

// Op names, the same snake_case the live hooks and metrics use.
const (
	OpSaveTable         = "save_table"
	OpLoadTable         = "load_table"
	OpDeleteTable       = "delete_table"
	OpListTables        = "list_tables"
	OpCountTables       = "count_tables"
	OpAppendChat        = "append_chat"
	OpLoadChat          = "load_chat"
	OpDeleteChat        = "delete_chat"
	OpSetSeated         = "set_seated"
	OpClearSeated       = "clear_seated"
	OpSeatOf            = "seat_of"
	OpListSeats         = "list_seats"
	OpSetOnline         = "set_online"
	OpSetOffline        = "set_offline"
	OpOnlineCount       = "online_count"
	OpPutResumeOffer    = "put_resume_offer"
	OpTakeResumeOffer   = "take_resume_offer"
	OpDeleteResumeOffer = "delete_resume_offer"
	OpPublishTable      = "publish_table"
	OpRetireTable       = "retire_table"
	OpCandidates        = "candidates"
	OpListSummaries     = "list_summaries"
	OpPing              = "ping"
	OpClose             = "close"
)

// Fake is the store. Zero value is not usable; use New / NewWithClock.
type Fake struct {
	mu     sync.Mutex
	now    func() time.Time
	closed bool

	tables    map[string]tableEntry
	chats     map[string][][]byte
	seats     map[string]string
	online    map[string]onlineEntry
	offers    map[string]offerEntry
	summaries map[string]live.TableSummary

	calls map[string]int
	fail  map[string]error
}

type tableEntry struct {
	seq       int64
	snapshot  []byte
	expiresAt time.Time
}

type onlineEntry struct {
	instance  string
	expiresAt time.Time
}

type offerEntry struct {
	offer     live.ResumeOffer
	expiresAt time.Time
}

// New returns a Fake reading the wall clock.
func New() *Fake { return NewWithClock(time.Now) }

// NewWithClock returns a Fake whose ttl expiry follows now (a test clock).
func NewWithClock(now func() time.Time) *Fake {
	if now == nil {
		now = time.Now
	}
	return &Fake{
		now:       now,
		tables:    map[string]tableEntry{},
		chats:     map[string][][]byte{},
		seats:     map[string]string{},
		online:    map[string]onlineEntry{},
		offers:    map[string]offerEntry{},
		summaries: map[string]live.TableSummary{},
		calls:     map[string]int{},
		fail:      map[string]error{},
	}
}

var _ live.Store = (*Fake)(nil)

// ---- test controls ---------------------------------------------------------

// Calls returns how many times op was called (failed calls included).
func (f *Fake) Calls(op string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.calls[op]
}

// Fail makes every later call of op return err (nil clears the failure).
func (f *Fake) Fail(op string, err error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err == nil {
		delete(f.fail, op)
		return
	}
	f.fail[op] = err
}

// Online reports the instance a user is online on, or ok=false when absent
// or expired. Does not count as a call.
func (f *Fake) Online(userID string) (instance string, ok bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	e, present := f.online[userID]
	if !present || !e.expiresAt.After(f.now()) {
		return "", false
	}
	return e.instance, true
}

// OnlineExpiry is when the user's presence entry lapses (zero when absent).
func (f *Fake) OnlineExpiry(userID string) time.Time {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.online[userID].expiresAt
}

// Offer peeks at a user's resume offer without taking it.
func (f *Fake) Offer(userID string) (live.ResumeOffer, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	e, present := f.offers[userID]
	if !present || !e.expiresAt.After(f.now()) {
		return live.ResumeOffer{}, false
	}
	return e.offer, true
}

// OfferExpiry is when the user's offer lapses (zero when absent).
func (f *Fake) OfferExpiry(userID string) time.Time {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.offers[userID].expiresAt
}

// Tables is the number of unexpired stored tables.
func (f *Fake) Tables() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, t := range f.tables {
		if t.expiresAt.After(f.now()) {
			n++
		}
	}
	return n
}

// Seed stores a snapshot directly (a "previous process" left it behind).
func (f *Fake) Seed(roomID string, seq int64, snapshot []byte) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.tables[roomID] = tableEntry{seq: seq, snapshot: append([]byte(nil), snapshot...), expiresAt: f.expiry(0)}
}

// Closed reports whether Close was called.
func (f *Fake) Closed() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.closed
}

// enter records the call and returns the injected failure, a closed-store
// error or the context's error, if any. mu held.
func (f *Fake) enter(ctx context.Context, op string) error {
	f.calls[op]++
	if err := ctx.Err(); err != nil {
		return err
	}
	if f.closed {
		return live.ErrClosed
	}
	if err := f.fail[op]; err != nil {
		return err
	}
	return nil
}

func (f *Fake) expiry(ttl time.Duration) time.Time {
	if ttl <= 0 {
		return time.Unix(1<<40, 0)
	}
	return f.now().Add(ttl)
}

// ---- live table state --------------------------------------------------------

func (f *Fake) SaveTable(ctx context.Context, roomID string, seq int64, snapshot []byte, ttl time.Duration) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.enter(ctx, OpSaveTable); err != nil {
		return err
	}
	if cur, ok := f.tables[roomID]; ok && cur.expiresAt.After(f.now()) && cur.seq >= seq {
		return live.ErrStale
	}
	f.tables[roomID] = tableEntry{seq: seq, snapshot: append([]byte(nil), snapshot...), expiresAt: f.expiry(ttl)}
	return nil
}

func (f *Fake) LoadTable(ctx context.Context, roomID string) (int64, []byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.enter(ctx, OpLoadTable); err != nil {
		return 0, nil, err
	}
	t, ok := f.tables[roomID]
	if !ok || !t.expiresAt.After(f.now()) {
		return 0, nil, live.ErrNotFound
	}
	return t.seq, append([]byte(nil), t.snapshot...), nil
}

func (f *Fake) DeleteTable(ctx context.Context, roomID string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.enter(ctx, OpDeleteTable); err != nil {
		return err
	}
	delete(f.tables, roomID)
	return nil
}

func (f *Fake) CountTables(ctx context.Context) (int, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.enter(ctx, OpCountTables); err != nil {
		return 0, err
	}
	n := 0
	for _, t := range f.tables {
		if t.expiresAt.After(f.now()) {
			n++
		}
	}
	return n, nil
}

func (f *Fake) ListTables(ctx context.Context) ([]live.TableRef, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.enter(ctx, OpListTables); err != nil {
		return nil, err
	}
	out := []live.TableRef{}
	for id, t := range f.tables {
		if t.expiresAt.After(f.now()) {
			out = append(out, live.TableRef{RoomID: id, Seq: t.seq})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].RoomID < out[j].RoomID })
	return out, nil
}

// ---- chat ------------------------------------------------------------------

func (f *Fake) AppendChat(ctx context.Context, roomID string, message []byte, max int) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.enter(ctx, OpAppendChat); err != nil {
		return err
	}
	msgs := append(f.chats[roomID], append([]byte(nil), message...))
	if max > 0 && len(msgs) > max {
		msgs = msgs[len(msgs)-max:]
	}
	f.chats[roomID] = msgs
	return nil
}

func (f *Fake) LoadChat(ctx context.Context, roomID string) ([][]byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.enter(ctx, OpLoadChat); err != nil {
		return nil, err
	}
	out := make([][]byte, 0, len(f.chats[roomID]))
	for _, m := range f.chats[roomID] {
		out = append(out, append([]byte(nil), m...))
	}
	return out, nil
}

func (f *Fake) DeleteChat(ctx context.Context, roomID string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.enter(ctx, OpDeleteChat); err != nil {
		return err
	}
	delete(f.chats, roomID)
	return nil
}

// ---- presence ---------------------------------------------------------------

func (f *Fake) SetSeated(ctx context.Context, userID, roomID string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.enter(ctx, OpSetSeated); err != nil {
		return err
	}
	f.seats[userID] = roomID
	return nil
}

func (f *Fake) ClearSeated(ctx context.Context, userID string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.enter(ctx, OpClearSeated); err != nil {
		return err
	}
	delete(f.seats, userID)
	return nil
}

func (f *Fake) SeatOf(ctx context.Context, userID string) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.enter(ctx, OpSeatOf); err != nil {
		return "", err
	}
	roomID, ok := f.seats[userID]
	if !ok {
		return "", live.ErrNotFound
	}
	return roomID, nil
}

func (f *Fake) ListSeats(ctx context.Context) (map[string]string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.enter(ctx, OpListSeats); err != nil {
		return nil, err
	}
	out := make(map[string]string, len(f.seats))
	for userID, roomID := range f.seats {
		out[userID] = roomID
	}
	return out, nil
}

func (f *Fake) SetOnline(ctx context.Context, userID, instance string, ttl time.Duration) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.enter(ctx, OpSetOnline); err != nil {
		return err
	}
	f.online[userID] = onlineEntry{instance: instance, expiresAt: f.expiry(ttl)}
	return nil
}

func (f *Fake) SetOffline(ctx context.Context, userID string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.enter(ctx, OpSetOffline); err != nil {
		return err
	}
	delete(f.online, userID)
	return nil
}

func (f *Fake) OnlineCount(ctx context.Context) (int, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.enter(ctx, OpOnlineCount); err != nil {
		return 0, err
	}
	n := 0
	for id, e := range f.online {
		if !e.expiresAt.After(f.now()) {
			delete(f.online, id)
			continue
		}
		n++
	}
	return n, nil
}

// ---- resume offers ----------------------------------------------------------

func (f *Fake) PutResumeOffer(ctx context.Context, userID string, offer live.ResumeOffer, ttl time.Duration) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.enter(ctx, OpPutResumeOffer); err != nil {
		return err
	}
	f.offers[userID] = offerEntry{offer: offer, expiresAt: f.expiry(ttl)}
	return nil
}

func (f *Fake) TakeResumeOffer(ctx context.Context, userID string) (live.ResumeOffer, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.enter(ctx, OpTakeResumeOffer); err != nil {
		return live.ResumeOffer{}, err
	}
	e, ok := f.offers[userID]
	if !ok {
		return live.ResumeOffer{}, live.ErrNotFound
	}
	delete(f.offers, userID)
	if !e.expiresAt.After(f.now()) {
		return live.ResumeOffer{}, live.ErrNotFound
	}
	return e.offer, nil
}

func (f *Fake) DeleteResumeOffer(ctx context.Context, userID string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.enter(ctx, OpDeleteResumeOffer); err != nil {
		return err
	}
	delete(f.offers, userID)
	return nil
}

// ---- matchmaking index -------------------------------------------------------

func (f *Fake) PublishTable(ctx context.Context, t live.TableSummary) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.enter(ctx, OpPublishTable); err != nil {
		return err
	}
	f.summaries[t.RoomID] = t
	return nil
}

func (f *Fake) RetireTable(ctx context.Context, roomID, category string, bootAmount int64) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.enter(ctx, OpRetireTable); err != nil {
		return err
	}
	delete(f.summaries, roomID)
	return nil
}

func (f *Fake) ListSummaries(ctx context.Context) ([]live.TableSummary, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.enter(ctx, OpListSummaries); err != nil {
		return nil, err
	}
	out := []live.TableSummary{}
	for _, s := range f.summaries {
		out = append(out, s)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].RoomID < out[j].RoomID })
	return out, nil
}

func (f *Fake) Candidates(ctx context.Context, category string, bootAmount int64) ([]live.TableSummary, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := f.enter(ctx, OpCandidates); err != nil {
		return nil, err
	}
	out := []live.TableSummary{}
	for _, s := range f.summaries {
		if s.IsPrivate || s.Category != category || s.BootAmount != bootAmount {
			continue
		}
		out = append(out, s)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Players != out[j].Players {
			return out[i].Players > out[j].Players
		}
		if out[i].CreatedAt != out[j].CreatedAt {
			return out[i].CreatedAt < out[j].CreatedAt
		}
		return out[i].RoomID < out[j].RoomID
	})
	return out, nil
}

// ---- lifecycle --------------------------------------------------------------

func (f *Fake) Ping(ctx context.Context) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.enter(ctx, OpPing)
}

func (f *Fake) Close() error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls[OpClose]++
	f.closed = true
	return nil
}

func (f *Fake) Kind() string { return "fake" }
