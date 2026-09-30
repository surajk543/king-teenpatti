package bot

import (
	"context"
	"errors"
	"time"

	"github.com/surajk543/king-teenpatti/bot-play/internal/bot/state"
	"github.com/surajk543/king-teenpatti/bot-play/internal/protocol"
)

// requestTimeout bounds every acknowledged request, as the Flutter client's
// 8-second ack timeout does.
const requestTimeout = 8 * time.Second

// Run is the bot's life until ctx ends or Stop is called: sessions of play
// separated by rests (brief §5, §19). It returns when the bot has stopped.
func (b *Bot) Run(ctx context.Context) {
	defer b.machine.To(state.Offline)
	for ctx.Err() == nil && !b.softStopped() {
		out := b.playSession(ctx)
		if out == outStopped || ctx.Err() != nil || b.softStopped() {
			return
		}
		if b.replenish {
			b.replenish = false
			b.generation++
			b.id = NewIdentity(b.d.Config.Bots.DevicePrefix, b.id.Index, b.id.Number, b.generation)
			b.session = state.Session{}
			continue
		}
		rest := b.restDuration(out)
		b.machine.To(state.Resting, "for", rest.Round(time.Second).String())
		select {
		case <-ctx.Done():
			return
		case <-b.soft:
			return
		case <-b.sleep(rest):
		}
	}
}

func (b *Bot) softStopped() bool {
	select {
	case <-b.soft:
		return true
	default:
		return false
	}
}

// sleep is a channel that fires after d on the bot's clock.
func (b *Bot) sleep(d time.Duration) <-chan time.Time { return b.d.Clock.NewTimer(d).C() }

// restDuration is the time offline between sessions (config session.rest_*),
// longer after a fatal refusal.
func (b *Bot) restDuration(out outcome) time.Duration {
	lo, hi := b.d.Config.Session.RestMin, b.d.Config.Session.RestMax
	if hi <= lo {
		hi = lo + time.Minute
	}
	d := time.Duration(b.rand.Between(float64(lo), float64(hi)))
	if out == outFatal {
		d *= 4
	}
	return d
}

// playSession is one session: sign in, connect, play tables until the
// session's planned length runs out, reconnecting as needed.
func (b *Bot) playSession(ctx context.Context) outcome {
	b.startSession()
	b.machine.To(state.Connecting)
	if err := b.signIn(ctx); err != nil {
		if errors.Is(err, errFatal) {
			return outFatal
		}
		return outStopped
	}
	for attempt := 0; ; attempt++ {
		if ctx.Err() != nil || b.softStopped() {
			return outStopped
		}
		if attempt > 0 {
			b.machine.To(state.Reconnecting, "attempt", attempt)
			if max := b.d.Config.Reconnect.MaxAttempts; max > 0 && attempt > max {
				b.log.Warn("reconnect attempts exhausted", "attempts", attempt-1)
				return outEnded
			}
			delay := b.backoff.Delay(attempt, b.rand)
			select {
			case <-ctx.Done():
				return outStopped
			case <-b.soft:
				return outStopped
			case <-b.sleep(delay):
			}
			b.machine.To(state.Connecting, "attempt", attempt)
		}
		sess, err := b.dial(ctx)
		if err != nil {
			var ce *protocol.ConnectError
			if errors.As(err, &ce) {
				switch ce.Message {
				case protocol.CodeUnknownUser, protocol.CodeInvalidSession, protocol.CodeMissingToken, protocol.CodeUnauthorized:
					// The account or the token is gone (a server whose
					// database was wiped): sign in again as a new session.
					if err := b.signIn(ctx); err != nil {
						if errors.Is(err, errFatal) {
							return outFatal
						}
						return outStopped
					}
				case protocol.CodeAccountDisabled:
					b.log.Error("account disabled: this bot cannot play", "code", ce.Message)
					return outFatal
				}
			}
			b.d.Metrics.Reconnect("failed")
			b.noteError(err)
			continue
		}
		if attempt > 0 {
			b.d.Metrics.Reconnect("ok")
			b.snapMu.Lock()
			b.snap.Reconnects++
			b.snapMu.Unlock()
		}
		b.d.Metrics.Connected()
		b.rejoin = attempt > 0
		out := b.loop(ctx, sess)
		switch out {
		case outLost:
			b.d.Metrics.Disconnected("lost")
			b.log.Warn("connection lost", "err", errString(sess.Err()))
			continue
		case outEnded:
			b.d.Metrics.Disconnected("session_end")
			return outEnded
		case outFatal:
			b.d.Metrics.Disconnected("fatal")
			return outFatal
		default:
			b.d.Metrics.Disconnected("stopped")
			return outStopped
		}
	}
}

var errFatal = errors.New("bot: this account cannot play")

// signIn logs in as the bot's guest device (retrying with backoff while the
// server is unreachable) and, in the lobby, puts on a free picture. The
// 6-hour bonus is collected when the stack runs short ([Bot.collectBonus]).
func (b *Bot) signIn(ctx context.Context) error {
	for attempt := 1; ; attempt++ {
		cctx, cancel := context.WithTimeout(ctx, 15*time.Second)
		res, err := b.d.API.Login(cctx, b.id.DeviceID, b.id.Name)
		cancel()
		if err == nil {
			b.token = res.Token
			b.userID = res.User.ID
			b.chips = res.User.Chips
			b.d.Fleet.AddBot(b.userID)
			b.book.Ignore(b.userID)
			b.log = b.d.Log.With("bot", b.id.DeviceID, "user", b.userID)
			if b.session.StartChips == 0 {
				b.session.StartChips = b.chips
			}
			b.session.Chips = b.chips
			b.publish()
			if res.IsNew {
				b.log.Info("new account", "welcome", res.WelcomeChips)
			}
			b.wearPicture(ctx, res.User)
			return nil
		}
		var apiErr *protocol.APIError
		if errors.As(err, &apiErr) && apiErr.Code == protocol.CodeAccountDisabled {
			b.log.Error("account disabled: this bot cannot play")
			return errFatal
		}
		b.noteError(err)
		b.log.Warn("login failed", "attempt", attempt, "err", err)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-b.soft:
			return context.Canceled
		case <-b.sleep(b.backoff.Delay(attempt, b.rand)):
		}
	}
}

// wearPicture puts a free profile picture on a bot that wears none, chosen
// from its number, so a table of bots is not five grey initials. Lobby only:
// a seated player is refused (409 seated), which is harmless here.
func (b *Bot) wearPicture(ctx context.Context, u protocol.User) {
	if u.ActivePictureID != nil {
		return
	}
	cctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	ids, err := b.d.API.FreePictureIDs(cctx)
	if err != nil || len(ids) == 0 {
		return
	}
	pick := ids[(b.id.Number*7+3)%len(ids)]
	if err := b.d.API.WearPicture(cctx, b.token, pick); err != nil {
		b.log.Debug("picture not worn", "err", err)
	}
}

// collectBonus claims the lobby's 6-hour bonus (25,000 chips), as any player
// may, when the bot's stack no longer admits it anywhere: kicked for chips,
// refused a seat for them, or no table on the menu taking its stack. Without
// it a broke bot would rest for ever, since the fleet never mints chips
// against a real server; with it, it sits again at a 200 table within six
// hours.
func (b *Bot) collectBonus(ctx context.Context) {
	if !b.d.Config.Bankroll.CollectBonus || b.seated {
		return
	}
	cctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	u, err := b.d.API.CollectBonus(cctx, b.token)
	if err != nil {
		return
	}
	if u.Chips > b.chips {
		b.log.Info("collected the timed bonus", "chips", u.Chips)
	}
	b.chips = u.Chips
	b.session.Chips = b.chips
}

// dial opens the game connection.
func (b *Bot) dial(ctx context.Context) (protocol.Session, error) {
	cctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	return b.d.Dialer.Dial(cctx, b.token)
}

// startSession plans a session: its length (the personality's habit inside
// config session.min/max) — brief §19.
func (b *Bot) startSession() {
	// The personality's habit, inside the configured range: config
	// session.min/max_duration are hard limits, the habit only narrows them.
	cfgLo, cfgHi := b.d.Config.Session.MinDuration, b.d.Config.Session.MaxDuration
	if cfgHi < cfgLo {
		cfgHi = cfgLo
	}
	lo, hi := cfgLo, cfgHi
	if p := b.persona.SessionMinutes; p[1] > 0 {
		plo := time.Duration(p[0] * float64(time.Minute))
		phi := time.Duration(p[1] * float64(time.Minute))
		lo = min(max(plo, cfgLo), cfgHi)
		hi = min(max(phi, lo), cfgHi)
	}
	if hi <= lo {
		hi = lo + 1 // a single length; Between needs a range
	}
	length := time.Duration(b.rand.Between(float64(lo), float64(hi)))
	now := b.now()
	b.session = state.Session{StartedAt: now, PlannedEnd: now.Add(length), StartChips: 0}
	b.log.Info("session planned", "length", length.Round(time.Minute).String(), "personality", string(b.persona.Kind))
}

// loop is the bot's single event loop for one connection: the server's
// events in order, the bot's own scheduled moves, and stop signals. It
// returns why it ended.
func (b *Bot) loop(ctx context.Context, sess protocol.Session) outcome {
	b.ctx = ctx
	b.sess = sess
	b.ready = false
	b.resume = nil
	b.outcome = outNone
	b.seated = false
	b.stopping = false
	defer func() {
		b.sched.clear()
		b.turnSeq++
		b.turnKey = ""
		if b.seated {
			b.d.Fleet.Unseat(b.userID)
		}
		b.d.Fleet.ReleaseClaim(b.userID) // a join this connection never settled
		b.seated = false
		_ = sess.Close()
		b.sess = nil
		b.publish()
	}()
	b.machine.To(state.Online)
	// Nothing to do until the server says hello; if it never does, give up
	// on this connection.
	b.sched.after(20*time.Second, "hello", func() {
		if !b.ready {
			b.log.Warn("no session:ready from the server")
			b.outcome = outLost
		}
	})
	b.sched.after(15*time.Second, "watch", b.watch)
	soft := b.soft
	for b.outcome == outNone {
		select {
		case <-ctx.Done():
			return outStopped
		case <-soft:
			soft = nil // handled once
			b.beginStop()
		case ev, ok := <-sess.Events():
			if !ok {
				return outLost
			}
			b.handle(ctx, ev)
		case <-b.sched.wake():
			b.sched.fire()
		}
	}
	return b.outcome
}

// beginStop is Stop arriving: leave now when not in a hand, else after it.
func (b *Bot) beginStop() {
	b.stopping = true
	if !b.seated || !b.handInProgress() {
		b.leaveThen("stopping", false, outStopped)
		return
	}
	b.endAfterHand = "stopping"
}

// watch runs every ~15 s while connected: the session's planned end, and a
// table that has gone idle (no hand for a long time).
func (b *Bot) watch() {
	defer b.sched.after(time.Duration(b.rand.Between(12, 20)*float64(time.Second)), "watch", b.watch)
	now := b.now()
	if !b.seated {
		return
	}
	if now.After(b.session.PlannedEnd) && !b.handInProgress() && b.endAfterHand == "" {
		b.leaveThen("session_over", true, outEnded)
		return
	}
	last := b.lastHandAt
	if b.joinedAt.After(last) {
		last = b.joinedAt
	}
	idle := time.Duration(b.rand.Between(70, 130) * float64(time.Second))
	if !b.handInProgress() && now.Sub(last) > idle && b.endAfterHand == "" {
		b.log.Info("table idle, moving on", "idle", now.Sub(last).Round(time.Second).String())
		b.exclude = append(b.exclude[:0], b.table.Key)
		b.leaveThen("idle_table", false, outNone)
	}
}

func errString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}
