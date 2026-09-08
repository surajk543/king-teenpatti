// Package livetest is a map-backed live.Store for the game package's unit
// tests: it records every call, lets a test inject failures (a save that
// errors, a save that is stale) and exposes what it holds. It is not the
// production memory store (internal/live) and makes no attempt at its
// TTL/atomicity semantics — tests here assert what the game package asks the
// store to do, not how the store does it.
package livetest

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/live"
)

// Save is one recorded SaveTable call.
type Save struct {
	RoomID   string
	Seq      int64
	Snapshot []byte
	TTL      time.Duration
}

// Store is the fake. Zero value is not usable; use New.
type Store struct {
	mu      sync.Mutex
	tables  map[string]Save
	chats   map[string][][]byte
	seats   map[string]string
	online  map[string]string
	offers  map[string]live.ResumeOffer
	index   map[string]live.TableSummary
	saves   []Save
	calls   []string
	closed  bool
	failure map[string]error

	// StaleSaves makes every SaveTable return live.ErrStale (the two-owners
	// fence) while true.
	StaleSaves bool
}

// New returns an empty store.
func New() *Store {
	return &Store{
		tables:  map[string]Save{},
		chats:   map[string][][]byte{},
		seats:   map[string]string{},
		online:  map[string]string{},
		offers:  map[string]live.ResumeOffer{},
		index:   map[string]live.TableSummary{},
		failure: map[string]error{},
	}
}

// Flush empties the store — a Redis that restarted without its data, or a
// FLUSHALL. The call log and the injected failures are kept.
func (s *Store) Flush() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.tables = map[string]Save{}
	s.chats = map[string][][]byte{}
	s.seats = map[string]string{}
	s.online = map[string]string{}
	s.offers = map[string]live.ResumeOffer{}
	s.index = map[string]live.TableSummary{}
	s.saves = nil
}

// Fail makes every call of op (snake_case method name, e.g. "save_table")
// return err until Fail(op, nil).
func (s *Store) Fail(op string, err error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err == nil {
		delete(s.failure, op)
		return
	}
	s.failure[op] = err
}

// record logs a call and returns the injected failure for op, if any.
func (s *Store) record(op string, detail ...any) error {
	parts := []string{op}
	for _, d := range detail {
		parts = append(parts, fmt.Sprint(d))
	}
	s.calls = append(s.calls, strings.Join(parts, ":"))
	return s.failure[op]
}

// Calls returns every recorded call, oldest first, as "op:detail:detail".
func (s *Store) Calls() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.calls...)
}

// CallsOf returns the recorded calls of one op.
func (s *Store) CallsOf(op string) []string {
	var out []string
	for _, c := range s.Calls() {
		if strings.HasPrefix(c, op+":") || c == op {
			out = append(out, c)
		}
	}
	return out
}

// Saves returns every SaveTable call that succeeded, oldest first.
func (s *Store) Saves() []Save {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]Save(nil), s.saves...)
}

// Stored returns the current snapshot of a table (ok=false when absent).
func (s *Store) Stored(roomID string) (Save, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	sv, ok := s.tables[roomID]
	return sv, ok
}

// Put stores a snapshot directly (to seed a restore, or plant garbage).
func (s *Store) Put(roomID string, seq int64, snapshot []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.tables[roomID] = Save{RoomID: roomID, Seq: seq, Snapshot: snapshot}
}

// Seats returns a copy of the seat index.
func (s *Store) Seats() map[string]string {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make(map[string]string, len(s.seats))
	for k, v := range s.seats {
		out[k] = v
	}
	return out
}

// Index returns a copy of the matchmaking index (roomId → summary).
func (s *Store) Index() map[string]live.TableSummary {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make(map[string]live.TableSummary, len(s.index))
	for k, v := range s.index {
		out[k] = v
	}
	return out
}

// Chat returns the stored chat lines of a room.
func (s *Store) Chat(roomID string) [][]byte {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([][]byte(nil), s.chats[roomID]...)
}

// ---- live.Store

func (s *Store) SaveTable(_ context.Context, roomID string, seq int64, snapshot []byte, ttl time.Duration) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.record("save_table", roomID, seq); err != nil {
		return err
	}
	if s.StaleSaves {
		return live.ErrStale
	}
	if cur, ok := s.tables[roomID]; ok && cur.Seq >= seq {
		return live.ErrStale
	}
	sv := Save{RoomID: roomID, Seq: seq, Snapshot: append([]byte(nil), snapshot...), TTL: ttl}
	s.tables[roomID] = sv
	s.saves = append(s.saves, sv)
	return nil
}

func (s *Store) LoadTable(_ context.Context, roomID string) (int64, []byte, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.record("load_table", roomID); err != nil {
		return 0, nil, err
	}
	sv, ok := s.tables[roomID]
	if !ok {
		return 0, nil, live.ErrNotFound
	}
	return sv.Seq, append([]byte(nil), sv.Snapshot...), nil
}

func (s *Store) DeleteTable(_ context.Context, roomID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.record("delete_table", roomID); err != nil {
		return err
	}
	delete(s.tables, roomID)
	return nil
}

func (s *Store) CountTables(_ context.Context) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.record("count_tables"); err != nil {
		return 0, err
	}
	return len(s.tables), nil
}

func (s *Store) ListTables(_ context.Context) ([]live.TableRef, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.record("list_tables"); err != nil {
		return nil, err
	}
	out := make([]live.TableRef, 0, len(s.tables))
	for id, sv := range s.tables {
		out = append(out, live.TableRef{RoomID: id, Seq: sv.Seq})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].RoomID < out[j].RoomID })
	return out, nil
}

func (s *Store) AppendChat(_ context.Context, roomID string, message []byte, max int) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.record("append_chat", roomID, max); err != nil {
		return err
	}
	lines := append(s.chats[roomID], append([]byte(nil), message...))
	if max > 0 && len(lines) > max {
		lines = lines[len(lines)-max:]
	}
	s.chats[roomID] = lines
	return nil
}

func (s *Store) LoadChat(_ context.Context, roomID string) ([][]byte, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.record("load_chat", roomID); err != nil {
		return nil, err
	}
	return append([][]byte(nil), s.chats[roomID]...), nil
}

func (s *Store) DeleteChat(_ context.Context, roomID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.record("delete_chat", roomID); err != nil {
		return err
	}
	delete(s.chats, roomID)
	return nil
}

func (s *Store) SetSeated(_ context.Context, userID, roomID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.record("set_seated", userID, roomID); err != nil {
		return err
	}
	s.seats[userID] = roomID
	return nil
}

func (s *Store) ClearSeated(_ context.Context, userID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.record("clear_seated", userID); err != nil {
		return err
	}
	delete(s.seats, userID)
	return nil
}

func (s *Store) ListSeats(_ context.Context) (map[string]string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.record("list_seats"); err != nil {
		return nil, err
	}
	out := make(map[string]string, len(s.seats))
	for userID, roomID := range s.seats {
		out[userID] = roomID
	}
	return out, nil
}

func (s *Store) SeatOf(_ context.Context, userID string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.record("seat_of", userID); err != nil {
		return "", err
	}
	roomID, ok := s.seats[userID]
	if !ok {
		return "", live.ErrNotFound
	}
	return roomID, nil
}

func (s *Store) SetOnline(_ context.Context, userID, instance string, _ time.Duration) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.record("set_online", userID); err != nil {
		return err
	}
	s.online[userID] = instance
	return nil
}

func (s *Store) SetOffline(_ context.Context, userID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.record("set_offline", userID); err != nil {
		return err
	}
	delete(s.online, userID)
	return nil
}

func (s *Store) OnlineCount(context.Context) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.record("online_count"); err != nil {
		return 0, err
	}
	return len(s.online), nil
}

func (s *Store) PutResumeOffer(_ context.Context, userID string, offer live.ResumeOffer, _ time.Duration) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.record("put_resume_offer", userID); err != nil {
		return err
	}
	s.offers[userID] = offer
	return nil
}

func (s *Store) TakeResumeOffer(_ context.Context, userID string) (live.ResumeOffer, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.record("take_resume_offer", userID); err != nil {
		return live.ResumeOffer{}, err
	}
	offer, ok := s.offers[userID]
	if !ok {
		return live.ResumeOffer{}, live.ErrNotFound
	}
	delete(s.offers, userID)
	return offer, nil
}

func (s *Store) DeleteResumeOffer(_ context.Context, userID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.record("delete_resume_offer", userID); err != nil {
		return err
	}
	delete(s.offers, userID)
	return nil
}

func (s *Store) PublishTable(_ context.Context, t live.TableSummary) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.record("publish_table", t.RoomID, t.Players, t.State); err != nil {
		return err
	}
	s.index[t.RoomID] = t
	return nil
}

func (s *Store) RetireTable(_ context.Context, roomID, category string, bootAmount int64) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.record("retire_table", roomID, category, bootAmount); err != nil {
		return err
	}
	delete(s.index, roomID)
	return nil
}

func (s *Store) ListSummaries(_ context.Context) ([]live.TableSummary, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.record("list_summaries"); err != nil {
		return nil, err
	}
	out := []live.TableSummary{}
	for _, t := range s.index {
		out = append(out, t)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].RoomID < out[j].RoomID })
	return out, nil
}

func (s *Store) Candidates(_ context.Context, category string, bootAmount int64) ([]live.TableSummary, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.record("candidates", category, bootAmount); err != nil {
		return nil, err
	}
	var out []live.TableSummary
	for _, t := range s.index {
		if !t.IsPrivate && t.Category == category && t.BootAmount == bootAmount {
			out = append(out, t)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Players != out[j].Players {
			return out[i].Players > out[j].Players
		}
		return out[i].CreatedAt < out[j].CreatedAt
	})
	return out, nil
}

func (s *Store) Ping(context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.record("ping"); err != nil {
		return err
	}
	if s.closed {
		return errors.New("livetest: closed")
	}
	return nil
}

func (s *Store) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.closed = true
	return nil
}

func (s *Store) Kind() string { return "livetest" }

var _ live.Store = (*Store)(nil)
