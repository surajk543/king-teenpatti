package live

import (
	"context"
	"sort"
	"sync"
	"time"
)

// memorySweepEvery bounds how long an expired entry nobody reads again can
// linger in the maps: every mutation that lands at least this long after the
// previous sweep walks every map once and drops what has expired. Reads still
// expire lazily on their own, so the sweep is only a memory bound.
const memorySweepEvery = time.Minute

// Memory is the in-process Store (REDIS_URL empty). It mirrors the Redis
// semantics exactly — CAS on seq, lazy ttl expiry, capped chat, atomic
// take of a resume offer, fullest-first matchmaking — behind one mutex, so
// a single instance behaves the same whichever store it was started with.
// Nothing survives a restart.
type Memory struct {
	mu        sync.Mutex
	now       func() time.Time
	lastSweep time.Time
	closed    bool

	tables    map[string]*memTable   // roomID → snapshot
	chats     map[string]*memChat    // roomID → capped messages
	seats     map[string]string      // userID → roomID
	online    map[string]memOnline   // userID → presence
	offers    map[string]memOffer    // userID → resume offer
	summaries map[string]*memSummary // roomID → lobby summary
	lobby     map[string]map[string]struct{}
	// lobby: bucket "<category>:<boot>" → public room ids published there
}

type memTable struct {
	seq       int64
	snapshot  []byte
	expiresAt time.Time
}

type memChat struct {
	messages  [][]byte
	expiresAt time.Time
}

type memOnline struct {
	instance  string
	expiresAt time.Time
}

type memOffer struct {
	offer     ResumeOffer
	expiresAt time.Time
}

type memSummary struct {
	summary   TableSummary
	expiresAt time.Time
}

// NewMemory returns the in-process Store used when REDIS_URL is empty.
func NewMemory() Store { return NewMemoryWithClock(time.Now) }

// NewMemoryWithClock returns a Memory store that reads the time from now —
// tests inject a fake clock to drive ttl expiry without sleeping.
func NewMemoryWithClock(now func() time.Time) Store {
	if now == nil {
		now = time.Now
	}
	m := &Memory{
		now:       now,
		tables:    make(map[string]*memTable),
		chats:     make(map[string]*memChat),
		seats:     make(map[string]string),
		online:    make(map[string]memOnline),
		offers:    make(map[string]memOffer),
		summaries: make(map[string]*memSummary),
		lobby:     make(map[string]map[string]struct{}),
	}
	m.lastSweep = now()
	return m
}

// Kind implements Store.
func (m *Memory) Kind() string { return "memory" }

// Ping implements Store.
func (m *Memory) Ping(ctx context.Context) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.enter(ctx)
}

// Close implements Store. Every later call fails with ErrClosed.
func (m *Memory) Close() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.closed = true
	return nil
}

// enter is the common preamble of every method, called with mu held: it
// honours a cancelled context, refuses a closed store and runs the periodic
// sweep of expired entries.
func (m *Memory) enter(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if m.closed {
		return ErrClosed
	}
	if now := m.now(); now.Sub(m.lastSweep) >= memorySweepEvery {
		m.sweep(now)
	}
	return nil
}

// sweep drops every expired entry from every map (mu held).
func (m *Memory) sweep(now time.Time) {
	m.lastSweep = now
	for id, t := range m.tables {
		if !t.expiresAt.After(now) {
			delete(m.tables, id)
		}
	}
	for id, c := range m.chats {
		if !c.expiresAt.After(now) {
			delete(m.chats, id)
		}
	}
	for id, o := range m.online {
		if !o.expiresAt.After(now) {
			delete(m.online, id)
		}
	}
	for id, o := range m.offers {
		if !o.expiresAt.After(now) {
			delete(m.offers, id)
		}
	}
	for id, s := range m.summaries {
		if !s.expiresAt.After(now) {
			m.dropSummary(id, s)
		}
	}
}

// expiry converts a ttl into an absolute deadline; ttl <= 0 means "never",
// which mirrors a Redis key without an expiry.
func (m *Memory) expiry(ttl time.Duration) time.Time {
	if ttl <= 0 {
		return farFuture
	}
	return m.now().Add(ttl)
}

// farFuture stands for "no expiry" in the memory store.
var farFuture = time.Unix(1<<40, 0)

// ---- live table state ----------------------------------------------------

// SaveTable implements Store: compare-and-set on the per-table seq.
func (m *Memory) SaveTable(ctx context.Context, roomID string, seq int64, snapshot []byte, ttl time.Duration) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.enter(ctx); err != nil {
		return err
	}
	if cur := m.liveTable(roomID); cur != nil && cur.seq >= seq {
		return ErrStale
	}
	m.tables[roomID] = &memTable{
		seq:       seq,
		snapshot:  append([]byte(nil), snapshot...),
		expiresAt: m.expiry(ttl),
	}
	return nil
}

// liveTable returns the stored table unless it expired (dropping it then).
func (m *Memory) liveTable(roomID string) *memTable {
	t, ok := m.tables[roomID]
	if !ok {
		return nil
	}
	if !t.expiresAt.After(m.now()) {
		delete(m.tables, roomID)
		return nil
	}
	return t
}

// LoadTable implements Store.
func (m *Memory) LoadTable(ctx context.Context, roomID string) (int64, []byte, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.enter(ctx); err != nil {
		return 0, nil, err
	}
	t := m.liveTable(roomID)
	if t == nil {
		return 0, nil, ErrNotFound
	}
	return t.seq, append([]byte(nil), t.snapshot...), nil
}

// DeleteTable implements Store.
func (m *Memory) DeleteTable(ctx context.Context, roomID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.enter(ctx); err != nil {
		return err
	}
	delete(m.tables, roomID)
	return nil
}

// ListTables implements Store; the result is sorted by room id.
func (m *Memory) ListTables(ctx context.Context) ([]TableRef, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.enter(ctx); err != nil {
		return nil, err
	}
	now := m.now()
	refs := make([]TableRef, 0, len(m.tables))
	for id, t := range m.tables {
		if !t.expiresAt.After(now) {
			delete(m.tables, id)
			continue
		}
		refs = append(refs, TableRef{RoomID: id, Seq: t.seq})
	}
	sort.Slice(refs, func(i, j int) bool { return refs[i].RoomID < refs[j].RoomID })
	return refs, nil
}

// ---- chat -----------------------------------------------------------------

// AppendChat implements Store. max <= 0 leaves the list uncapped.
func (m *Memory) AppendChat(ctx context.Context, roomID string, message []byte, max int) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.enter(ctx); err != nil {
		return err
	}
	c := m.liveChat(roomID)
	if c == nil {
		c = &memChat{}
		m.chats[roomID] = c
	}
	c.messages = append(c.messages, append([]byte(nil), message...))
	if max > 0 && len(c.messages) > max {
		// Re-slice into a fresh array so the dropped heads are collectable.
		kept := make([][]byte, max)
		copy(kept, c.messages[len(c.messages)-max:])
		c.messages = kept
	}
	c.expiresAt = m.expiry(auxTTL)
	return nil
}

func (m *Memory) liveChat(roomID string) *memChat {
	c, ok := m.chats[roomID]
	if !ok {
		return nil
	}
	if !c.expiresAt.After(m.now()) {
		delete(m.chats, roomID)
		return nil
	}
	return c
}

// LoadChat implements Store; oldest first, never nil.
func (m *Memory) LoadChat(ctx context.Context, roomID string) ([][]byte, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.enter(ctx); err != nil {
		return nil, err
	}
	c := m.liveChat(roomID)
	if c == nil {
		return [][]byte{}, nil
	}
	out := make([][]byte, len(c.messages))
	for i, msg := range c.messages {
		out[i] = append([]byte(nil), msg...)
	}
	return out, nil
}

// DeleteChat implements Store.
func (m *Memory) DeleteChat(ctx context.Context, roomID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.enter(ctx); err != nil {
		return err
	}
	delete(m.chats, roomID)
	return nil
}

// ---- presence -------------------------------------------------------------

// SetSeated implements Store.
func (m *Memory) SetSeated(ctx context.Context, userID, roomID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.enter(ctx); err != nil {
		return err
	}
	m.seats[userID] = roomID
	return nil
}

// ClearSeated implements Store.
func (m *Memory) ClearSeated(ctx context.Context, userID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.enter(ctx); err != nil {
		return err
	}
	delete(m.seats, userID)
	return nil
}

// SeatOf implements Store.
func (m *Memory) SeatOf(ctx context.Context, userID string) (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.enter(ctx); err != nil {
		return "", err
	}
	roomID, ok := m.seats[userID]
	if !ok {
		return "", ErrNotFound
	}
	return roomID, nil
}

// SetOnline implements Store: the entry lives until now+ttl unless refreshed.
func (m *Memory) SetOnline(ctx context.Context, userID, instance string, ttl time.Duration) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.enter(ctx); err != nil {
		return err
	}
	m.online[userID] = memOnline{instance: instance, expiresAt: m.expiry(ttl)}
	return nil
}

// SetOffline implements Store.
func (m *Memory) SetOffline(ctx context.Context, userID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.enter(ctx); err != nil {
		return err
	}
	delete(m.online, userID)
	return nil
}

// OnlineCount implements Store: counts unexpired entries and reaps the rest.
func (m *Memory) OnlineCount(ctx context.Context) (int, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.enter(ctx); err != nil {
		return 0, err
	}
	now := m.now()
	n := 0
	for id, o := range m.online {
		if !o.expiresAt.After(now) {
			delete(m.online, id)
			continue
		}
		n++
	}
	return n, nil
}

// ---- resume offers --------------------------------------------------------

// PutResumeOffer implements Store.
func (m *Memory) PutResumeOffer(ctx context.Context, userID string, offer ResumeOffer, ttl time.Duration) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.enter(ctx); err != nil {
		return err
	}
	m.offers[userID] = memOffer{offer: offer, expiresAt: m.expiry(ttl)}
	return nil
}

// TakeResumeOffer implements Store: get-and-delete under the one mutex.
func (m *Memory) TakeResumeOffer(ctx context.Context, userID string) (ResumeOffer, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.enter(ctx); err != nil {
		return ResumeOffer{}, err
	}
	o, ok := m.offers[userID]
	if !ok {
		return ResumeOffer{}, ErrNotFound
	}
	delete(m.offers, userID)
	if !o.expiresAt.After(m.now()) {
		return ResumeOffer{}, ErrNotFound
	}
	return o.offer, nil
}

// DeleteResumeOffer implements Store.
func (m *Memory) DeleteResumeOffer(ctx context.Context, userID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.enter(ctx); err != nil {
		return err
	}
	delete(m.offers, userID)
	return nil
}

// ---- matchmaking index ----------------------------------------------------

// PublishTable implements Store.
func (m *Memory) PublishTable(ctx context.Context, t TableSummary) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.enter(ctx); err != nil {
		return err
	}
	// A re-publish into a different bucket (or as private) must not leave the
	// old index entry behind.
	if prev, ok := m.summaries[t.RoomID]; ok {
		m.unindex(prev.summary)
	}
	m.summaries[t.RoomID] = &memSummary{summary: t, expiresAt: m.expiry(auxTTL)}
	if !t.IsPrivate {
		bucket := lobbyBucket(t.Category, t.BootAmount)
		ids := m.lobby[bucket]
		if ids == nil {
			ids = make(map[string]struct{})
			m.lobby[bucket] = ids
		}
		ids[t.RoomID] = struct{}{}
	}
	return nil
}

// unindex removes a summary's lobby entry (mu held).
func (m *Memory) unindex(s TableSummary) {
	bucket := lobbyBucket(s.Category, s.BootAmount)
	if ids := m.lobby[bucket]; ids != nil {
		delete(ids, s.RoomID)
		if len(ids) == 0 {
			delete(m.lobby, bucket)
		}
	}
}

// dropSummary forgets a summary and its index entry (mu held).
func (m *Memory) dropSummary(roomID string, s *memSummary) {
	m.unindex(s.summary)
	delete(m.summaries, roomID)
}

// RetireTable implements Store.
func (m *Memory) RetireTable(ctx context.Context, roomID, category string, bootAmount int64) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.enter(ctx); err != nil {
		return err
	}
	if ids := m.lobby[lobbyBucket(category, bootAmount)]; ids != nil {
		delete(ids, roomID)
		if len(ids) == 0 {
			delete(m.lobby, lobbyBucket(category, bootAmount))
		}
	}
	if s, ok := m.summaries[roomID]; ok {
		m.dropSummary(roomID, s)
	}
	return nil
}

// Candidates implements Store: the bucket's public tables, fullest first,
// ties oldest first. Never nil.
func (m *Memory) Candidates(ctx context.Context, category string, bootAmount int64) ([]TableSummary, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.enter(ctx); err != nil {
		return nil, err
	}
	now := m.now()
	out := []TableSummary{}
	for id := range m.lobby[lobbyBucket(category, bootAmount)] {
		s, ok := m.summaries[id]
		if !ok {
			continue
		}
		if !s.expiresAt.After(now) {
			m.dropSummary(id, s)
			continue
		}
		out = append(out, s.summary)
	}
	sort.Slice(out, func(i, j int) bool { return lessCandidate(out[i], out[j]) })
	return out, nil
}
