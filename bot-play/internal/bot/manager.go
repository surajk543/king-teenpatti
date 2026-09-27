package bot

import (
	"context"
	"sort"
	"sync"
	"time"

	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/state"
)

// Manager runs a fleet of bots, each on its own goroutine with its own
// connection, state and random stream, so one slow or disconnected bot never
// holds up another (brief §4). It starts them staggered — a fleet that
// arrives all at once is one program with many sockets — and stops them
// gracefully: every bot finishes its hand, leaves its table and disconnects.
type Manager struct {
	d Deps

	mu       sync.Mutex
	bots     []*Bot
	running  map[string]*run
	started  bool
	stopping chan struct{} // closed by Stop: the launcher starts nobody else
	launched chan struct{} // closed when the launcher is done
}

type run struct {
	bot    *Bot
	cancel context.CancelFunc
	done   chan struct{}
}

// NewManager builds the fleet's bots from the configuration (bots.count,
// bots.device_prefix, bots.start_index). They do not start until Start.
func NewManager(d Deps) *Manager {
	m := &Manager{d: d, running: map[string]*run{}, stopping: make(chan struct{}), launched: make(chan struct{})}
	cfg := d.Config.Bots
	for i := 0; i < cfg.Count; i++ {
		id := NewIdentity(cfg.DevicePrefix, i, cfg.StartIndex+i, 0)
		m.bots = append(m.bots, New(id, d))
	}
	return m
}

// Bots is the fleet, in order.
func (m *Manager) Bots() []*Bot {
	m.mu.Lock()
	defer m.mu.Unlock()
	return append([]*Bot(nil), m.bots...)
}

// Start launches every bot, staggered by a random gap each (config
// bots.start_stagger), and returns at once; ctx ending stops them hard.
func (m *Manager) Start(ctx context.Context) {
	m.mu.Lock()
	if m.started {
		m.mu.Unlock()
		return
	}
	m.started = true
	bots := append([]*Bot(nil), m.bots...)
	m.mu.Unlock()

	go func() {
		defer close(m.launched)
		lo, hi := m.d.Config.Bots.StartStagger[0], m.d.Config.Bots.StartStagger[1]
		for i, b := range bots {
			if i > 0 && hi > 0 {
				gap := time.Duration(b.rand.Between(float64(lo), float64(max(hi, lo+1))))
				select {
				case <-ctx.Done():
					return
				case <-m.stopping:
					return
				case <-m.d.Clock.NewTimer(gap).C():
				}
			}
			select {
			case <-m.stopping:
				return // a stop during the staggered start: nobody else starts
			default:
			}
			m.launch(ctx, b)
		}
	}()
	go m.heartbeat(ctx)
}

func (m *Manager) launch(ctx context.Context, b *Bot) {
	bctx, cancel := context.WithCancel(ctx)
	r := &run{bot: b, cancel: cancel, done: make(chan struct{})}
	m.mu.Lock()
	m.running[b.ID()] = r
	m.mu.Unlock()
	go func() {
		defer close(r.done)
		defer func() {
			if p := recover(); p != nil {
				b.log.Error("bot crashed", "panic", p)
			}
		}()
		b.Run(bctx)
	}()
}

// Stop asks every bot to finish its hand, leave and disconnect, and waits
// until they have or ctx ends — then stops the rest hard. It returns how many
// bots had to be stopped hard.
func (m *Manager) Stop(ctx context.Context) int {
	m.mu.Lock()
	select {
	case <-m.stopping:
	default:
		close(m.stopping)
	}
	started := m.started
	m.mu.Unlock()
	if started {
		// Wait for the launcher to notice, so no bot starts after this and
		// escapes the graceful stop below.
		select {
		case <-m.launched:
		case <-ctx.Done():
		}
	}
	m.mu.Lock()
	runs := make([]*run, 0, len(m.running))
	for _, r := range m.running {
		runs = append(runs, r)
	}
	m.mu.Unlock()
	for _, r := range runs {
		r.bot.Stop()
	}
	hard := 0
	for _, r := range runs {
		select {
		case <-r.done:
		case <-ctx.Done():
			hard++
			r.cancel()
			<-r.done
		}
	}
	return hard
}

// Restart stops one bot gracefully (bounded by ctx) and starts a fresh one
// with the same identity. false when no such bot runs.
func (m *Manager) Restart(ctx context.Context, deviceID string) bool {
	m.mu.Lock()
	r, ok := m.running[deviceID]
	m.mu.Unlock()
	if !ok {
		return false
	}
	r.bot.Stop()
	select {
	case <-r.done:
	case <-ctx.Done():
		r.cancel()
		<-r.done
	}
	fresh := New(r.bot.id, m.d)
	m.mu.Lock()
	for i, b := range m.bots {
		if b == r.bot {
			m.bots[i] = fresh
		}
	}
	m.mu.Unlock()
	m.launch(context.WithoutCancel(ctx), fresh)
	return true
}

// Snapshots is every bot as the debug view shows it, ordered by id.
func (m *Manager) Snapshots() []state.Snapshot {
	bots := m.Bots()
	out := make([]state.Snapshot, 0, len(bots))
	for _, b := range bots {
		out = append(out, b.Snapshot())
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Bot < out[j].Bot })
	return out
}

// Health is the fleet in a few numbers.
type Health struct {
	Bots    int                 `json:"bots"`
	Running int                 `json:"running"`
	Seated  int                 `json:"seated"`
	ByState map[state.State]int `json:"byState"`
	Hands   int                 `json:"hands"`
}

// Health reports the fleet's state.
func (m *Manager) Health() Health {
	h := Health{ByState: map[state.State]int{}}
	m.mu.Lock()
	h.Bots = len(m.bots)
	for _, r := range m.running {
		select {
		case <-r.done:
		default:
			h.Running++
		}
	}
	m.mu.Unlock()
	for _, s := range m.Snapshots() {
		h.ByState[s.State]++
		h.Hands += s.SessionHands
	}
	h.Seated = m.d.Fleet.Seated()
	return h
}

// heartbeat logs the fleet's health every few minutes.
func (m *Manager) heartbeat(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case <-m.d.Clock.NewTimer(5 * time.Minute).C():
		}
		h := m.Health()
		states := make([]any, 0, 2*len(h.ByState))
		for s, n := range h.ByState {
			states = append(states, string(s), n)
		}
		m.d.Log.Info("fleet", append([]any{"bots", h.Bots, "running", h.Running, "seated", h.Seated, "hands", h.Hands}, states...)...)
	}
}
