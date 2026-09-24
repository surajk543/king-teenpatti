package db

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"math/big"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// The prizes a Lucky Draw slot may hold (lucky_draw_slots.reward_type; owner,
// 24 Sep 2026). TEXT in the database and checked here rather than by an ENUM or
// a CHECK, so a later kind of prize — an AVATAR_FRAME, a CARD_BACK, a TITLE — is
// a row and a release, never a change to a constraint every existing database
// already carries. Until a build knows how to grant one, a slot holding it is
// left out of the draw with a logged reason (LuckyDraws.slots).
const (
	LuckyRewardChips          = "CHIPS"
	LuckyRewardDiamond        = "DIAMOND"
	LuckyRewardHammer         = "HAMMER"
	LuckyRewardMissile        = "MISSILE"
	LuckyRewardProfilePicture = "PROFILE_PICTURE"
	LuckyRewardTablePicture   = "TABLE_PICTURE"
	// LuckyRewardNone is a slot that pays nothing — "better luck next time"
	// (the owner's BEGINNER_LUCKY_DRAW, slot 5). Its spin is recorded and starts
	// the cooldown like any other; its reward_value, if any, is not read.
	LuckyRewardNone = "NO_REWARD"
)

// LuckyDrawSlots is how many slots a wheel has; lucky_draw_slots.slot_number
// runs 1 to LuckyDrawSlots, clockwise from the top.
const LuckyDrawSlots = 6

// Lucky Draw refusals the HTTP layer turns into wire codes.
var (
	// ErrLuckyDrawUnavailable is no active draw with that code, or an active
	// draw with no slot this server can grant.
	ErrLuckyDrawUnavailable = errors.New("lucky_draw_unavailable")
	// ErrLuckyDrawActionID is a spin with no key to make it idempotent.
	ErrLuckyDrawActionID = errors.New("invalid_action_id")
)

// LuckyDrawCooldown refuses a spin made before the draw has recharged for this
// player: NextSpinAt (epoch ms) is when it will have. Nothing was drawn,
// granted or recorded.
type LuckyDrawCooldown struct {
	NextSpinAt int64
}

func (e *LuckyDrawCooldown) Error() string {
	return fmt.Sprintf("lucky_draw_not_ready: next spin at %d", e.NextSpinAt)
}

// LuckyDrawActionID is the key a spin is recorded under, in user_lucky_draws
// and — for a CHIPS prize — in chip_ledger: "lucky:<userId>:<actionId>".
// Scoped by the player, so one player's action id can never occupy, or replay,
// another's spin, and prefixed so a ledger row says where it came from.
func LuckyDrawActionID(userID, actionID string) string {
	return "lucky:" + userID + ":" + actionID
}

// LuckyDraw is a draw as a client sees it (GET /api/lucky-draw).
type LuckyDraw struct {
	Code string `json:"code"`
	Name string `json:"name"`
	// SpinnerType is what kind of draw it is — BEGINNER for the owner's first
	// one (lucky_draws.spinner_type). The app has one wheel and draws it for
	// every type.
	SpinnerType string `json:"spinnerType"`
	// CooldownMs is how long after a spin the next one is allowed; 0 is
	// whenever the player likes.
	CooldownMs int64 `json:"cooldownMs"`
}

// LuckyDrawSlot is one slot of a wheel as a client sees it: its place and its
// prize. Never its weight — how likely a slot is stays on the server, and a
// client has no use for it: the server draws.
type LuckyDrawSlot struct {
	SlotNumber int `json:"slotNumber"`
	// RewardType is one of the LuckyReward* kinds; RewardValue the amount of a
	// CHIPS, DIAMOND, HAMMER or MISSILE prize and null for a picture;
	// RewardRefID the catalogue id of a PROFILE_PICTURE or TABLE_PICTURE prize
	// and null for an amount.
	RewardType  string  `json:"rewardType"`
	RewardValue *int64  `json:"rewardValue"`
	RewardRefID *string `json:"rewardRefId"`
	// Picture is a PROFILE_PICTURE prize's catalogue row, exactly as GET
	// /api/profiles serves it, with Owned and ExpiresAt resolved for the
	// viewer; TablePicture is a TABLE_PICTURE prize's, as GET
	// /api/table-pictures serves it. At most one is set, so a client draws the
	// prize with the loaders it already has.
	Picture      *Picture      `json:"picture,omitempty"`
	TablePicture *TablePicture `json:"tablePicture,omitempty"`

	id     int64 // lucky_draw_slots.id: what a spin's record points at
	weight int64
}

// LuckyDrawState is GET /api/lucky-draw: the draw, its slots in wheel order
// (only those that can be won), and when this player may next spin — 0 when
// they may now. The client counts down to NextSpinAt; the server decides.
type LuckyDrawState struct {
	Draw       LuckyDraw       `json:"draw"`
	Slots      []LuckyDrawSlot `json:"slots"`
	NextSpinAt int64           `json:"nextSpinAt"`
}

// LuckyDrawReward is the prize a spin granted, as it stood when it was won —
// the snapshot user_lucky_draws keeps — with the picture's catalogue row beside
// it for a picture prize (LuckyDrawSlot.Picture says why).
type LuckyDrawReward struct {
	Type         string        `json:"type"`
	Value        *int64        `json:"value"`
	RefID        *string       `json:"refId"`
	Picture      *Picture      `json:"picture,omitempty"`
	TablePicture *TablePicture `json:"tablePicture,omitempty"`
}

// LuckyDrawSpin is what Spin did (POST /api/lucky-draw/spin).
type LuckyDrawSpin struct {
	// ActionID is the client's key for this spin, as it sent it.
	ActionID string `json:"actionId"`
	// SlotNumber is the slot the SERVER drew — the one the wheel stops on.
	SlotNumber int             `json:"slotNumber"`
	Reward     LuckyDrawReward `json:"reward"`
	// AlreadyOwned is a picture prize the player already had, free or bought
	// and still running: the spin is recorded, nothing more is granted, and the
	// rental they have is left exactly as it was.
	AlreadyOwned bool `json:"alreadyOwned"`
	// Replayed is a spin this action id had already made: the same answer
	// again, and nothing granted this time.
	Replayed bool `json:"replayed"`
	// NextSpinAt is when this player may spin this draw again; 0 now.
	NextSpinAt int64 `json:"nextSpinAt"`
	// User is the account after the spin, wallets and pictures included.
	User *User `json:"user"`
}

// LuckyDraws is the Lucky Draw (owner, 24 Sep 2026): the draws and their slots
// — configuration, read on each request, so an owner's UPDATE is on the wheel
// at the next look — and the spin, which picks the slot, grants its prize and
// records the spin in one transaction.
type LuckyDraws struct {
	db     *DB
	users  *Users
	clock  func() time.Time
	logger *slog.Logger // may be nil
	// pick returns a uniformly random integer in [0, n). crypto/rand, always:
	// a prize is worth something, so the draw uses the same source the deck is
	// shuffled with (game/deck.go), never math/rand. Tests fix it
	// (export_test.go).
	pick func(n int64) (int64, error)
}

// NewLuckyDraws builds the store. users builds the account a spin answers
// with; clock nil → time.Now; logger nil → a slot left out is not reported.
func NewLuckyDraws(d *DB, users *Users, clock func() time.Time, logger *slog.Logger) *LuckyDraws {
	return &LuckyDraws{db: d, users: users, clock: clock, logger: logger, pick: cryptoPick}
}

// cryptoPick is a uniform draw from [0, n) off crypto/rand.
func cryptoPick(n int64) (int64, error) {
	if n <= 0 {
		return 0, fmt.Errorf("lucky draw: nothing to draw from (%d)", n)
	}
	v, err := rand.Int(rand.Reader, big.NewInt(n))
	if err != nil {
		return 0, err
	}
	return v.Int64(), nil
}

// luckyDrawRow is one lucky_draws row: the client's view and its id.
type luckyDrawRow struct {
	LuckyDraw
	id int64
}

// loadDraw is the ACTIVE draw with this code, or — code "" — the first active
// draw in sort_order, which is the one the lobby opens; ErrLuckyDrawUnavailable
// when there is none, or it is retired.
func loadDraw(ctx context.Context, q queryer, code string) (luckyDrawRow, error) {
	var d luckyDrawRow
	const columns = `SELECT id, code, name, spinner_type, cooldown_ms FROM lucky_draws `
	var row pgx.Row
	if code == "" {
		row = q.QueryRow(ctx, columns+`WHERE is_active ORDER BY sort_order, id LIMIT 1`)
	} else {
		row = q.QueryRow(ctx, columns+`WHERE code = $1 AND is_active`, code)
	}
	err := row.Scan(&d.id, &d.Code, &d.Name, &d.SpinnerType, &d.CooldownMs)
	if errors.Is(err, pgx.ErrNoRows) {
		return luckyDrawRow{}, ErrLuckyDrawUnavailable
	}
	return d, err
}

// State is GET /api/lucky-draw for one player: the draw (code "" — the first
// active one), the slots that can be won, and when they may next spin.
// ErrLuckyDrawUnavailable when the draw is missing, retired, or has no slot
// this server can grant.
func (l *LuckyDraws) State(ctx context.Context, userID, code string) (*LuckyDrawState, error) {
	var out *LuckyDrawState
	err := l.db.WithTx(ctx, func(tx pgx.Tx) error {
		draw, err := loadDraw(ctx, tx, code)
		if err != nil {
			return err
		}
		slots, err := l.slots(ctx, tx, draw, userID)
		if err != nil {
			return err
		}
		if len(slots) == 0 {
			return ErrLuckyDrawUnavailable
		}
		next, err := l.nextSpinAt(ctx, tx, userID, draw, now(l.clock))
		if err != nil {
			return err
		}
		out = &LuckyDrawState{Draw: draw.LuckyDraw, Slots: slots, NextSpinAt: next}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}

// lastSpinAt is when this player last spun this draw (epoch ms), 0 never.
func lastSpinAt(ctx context.Context, q queryer, userID string, drawID int64) (int64, error) {
	var last int64
	err := q.QueryRow(ctx,
		`SELECT COALESCE(max(created_at), 0) FROM user_lucky_draws WHERE user_id = $1 AND lucky_draw_id = $2`,
		userID, drawID).Scan(&last)
	return last, err
}

// nextSpinAt is when this player may spin the draw again, or 0 when they may
// at `at`: a draw with no cooldown is always 0, and so is one they have never
// spun or whose cooldown has run out.
func (l *LuckyDraws) nextSpinAt(ctx context.Context, q queryer, userID string, draw luckyDrawRow, at int64) (int64, error) {
	if draw.CooldownMs <= 0 {
		return 0, nil
	}
	last, err := lastSpinAt(ctx, q, userID, draw.id)
	if err != nil || last == 0 {
		return 0, err
	}
	if next := last + draw.CooldownMs; next > at {
		return next, nil
	}
	return 0, nil
}

// slotRow is one lucky_draw_slots row as stored.
type slotRow struct {
	id         int64
	number     int16
	rewardType string
	value      *int64
	ref        *string
	weight     int64
}

// slots are the draw's slots a spin may land on, in wheel order, with their
// pictures resolved for userID: the ACTIVE rows whose prize this server can
// grant. A row it cannot is left out and logged, never refused at the spin —
// a draw with one bad slot still runs on the others:
//
//   - a type this build does not know;
//   - CHIPS, DIAMOND, HAMMER or MISSILE with no amount, or 0, or — for the three
//     INTEGER wallets — more than a wallet column can ever hold;
//   - PROFILE_PICTURE or TABLE_PICTURE whose reward_ref_id names no catalogue
//     row, or a retired one: a retired picture cannot be worn, so winning it
//     would be winning nothing.
//
// Read inside a spin's transaction, after the wallet lock, so whether a
// picture is already the player's cannot change between the look and the
// grant.
func (l *LuckyDraws) slots(ctx context.Context, q queryer, draw luckyDrawRow, userID string) ([]LuckyDrawSlot, error) {
	rows, err := q.Query(ctx,
		`SELECT id, slot_number, reward_type, reward_value, reward_ref_id, weight
		   FROM lucky_draw_slots
		  WHERE lucky_draw_id = $1 AND is_active
		  ORDER BY slot_number`, draw.id)
	if err != nil {
		return nil, err
	}
	// Read to the end before any other query: a transaction serves one result
	// at a time, and the pictures below are queries of their own.
	var raw []slotRow
	for rows.Next() {
		var r slotRow
		if err := rows.Scan(&r.id, &r.number, &r.rewardType, &r.value, &r.ref, &r.weight); err != nil {
			rows.Close()
			return nil, err
		}
		raw = append(raw, r)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}

	stamp := now(l.clock)
	slots := make([]LuckyDrawSlot, 0, len(raw))
	for _, r := range raw {
		slot := LuckyDrawSlot{
			SlotNumber:  int(r.number),
			RewardType:  r.rewardType,
			RewardValue: r.value,
			RewardRefID: r.ref,
			id:          r.id,
			weight:      r.weight,
		}
		reason, err := l.resolve(ctx, q, &slot, userID, stamp)
		if err != nil {
			return nil, err
		}
		if reason != "" {
			if l.logger != nil {
				l.logger.Warn("lucky draw slot left out",
					"draw", draw.Code, "slot", slot.SlotNumber, "rewardType", slot.RewardType, "reason", reason)
			}
			continue
		}
		slots = append(slots, slot)
	}
	return slots, nil
}

// resolve checks that a slot's prize can be granted and, for a picture, reads
// its catalogue row onto the slot. It answers with why the slot must be left
// out, or "" when it may be drawn.
func (l *LuckyDraws) resolve(ctx context.Context, q queryer, slot *LuckyDrawSlot, userID string, at int64) (string, error) {
	if slot.weight <= 0 {
		return "weight is not positive", nil // the CHECK forbids it
	}
	switch slot.RewardType {
	case LuckyRewardNone:
		// Pays nothing, so there is nothing to check.
	case LuckyRewardChips:
		if slot.RewardValue == nil || *slot.RewardValue <= 0 {
			return "no amount", nil
		}
	case LuckyRewardDiamond, LuckyRewardHammer, LuckyRewardMissile:
		if slot.RewardValue == nil || *slot.RewardValue <= 0 {
			return "no amount", nil
		}
		if *slot.RewardValue > math.MaxInt32 {
			return "more than the wallet can hold", nil
		}
	case LuckyRewardProfilePicture:
		id, ok := refID(slot.RewardRefID)
		if !ok {
			return "no picture id", nil
		}
		pic, active, found, err := findPictureIn(ctx, q, userID, id, at)
		if err != nil {
			return "", err
		}
		if !found {
			return "no such profile picture", nil
		}
		if !active {
			return "the profile picture is retired", nil
		}
		slot.Picture = &pic
	case LuckyRewardTablePicture:
		id, ok := refID(slot.RewardRefID)
		if !ok {
			return "no table picture id", nil
		}
		pic, active, found, err := findTablePictureIn(ctx, q, userID, id, at)
		if err != nil {
			return "", err
		}
		if !found {
			return "no such table picture", nil
		}
		if !active {
			return "the table picture is retired", nil
		}
		slot.TablePicture = &pic
	default:
		return "a prize this server cannot grant", nil
	}
	return "", nil
}

// refID reads a catalogue id out of reward_ref_id.
func refID(ref *string) (int64, bool) {
	if ref == nil {
		return 0, false
	}
	id, err := strconv.ParseInt(*ref, 10, 64)
	return id, err == nil && id > 0
}

// findPictureIn is Pictures.Find on a transaction: one profile picture with
// this viewer's ownership resolved at `at`, whether or not it is on offer.
func findPictureIn(ctx context.Context, q queryer, userID string, id, at int64) (pic Picture, active, found bool, err error) {
	err = q.QueryRow(ctx,
		`SELECT `+pictureColumns+`, p.is_active, `+ownedExpr+`, `+expiryExpr+`
		   FROM profile_pictures p`+fmt.Sprintf(ownedJoin, at)+`
		  WHERE p.id = $2`, userID, id).
		Scan(&pic.ID, &pic.Name, &pic.URL, &pic.AssetFormat, &pic.Currency, &pic.Type, &pic.Cost, &pic.DurationDays, &pic.DurationHours,
			&pic.SortOrder, &active, &pic.Owned, &pic.ExpiresAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Picture{}, false, false, nil
	}
	return pic, active, err == nil, err
}

// findTablePictureIn is TablePictures.Find on a transaction.
func findTablePictureIn(ctx context.Context, q queryer, userID string, id, at int64) (pic TablePicture, active, found bool, err error) {
	pic, active, err = scanTablePicture(q.QueryRow(ctx,
		`SELECT `+tablePictureColumns+`, p.is_active, `+ownedExpr+`, `+expiryExpr+`
		   FROM table_pictures p`+fmt.Sprintf(tableOwnedJoin, at)+`
		  WHERE p.id = $2`, userID, id))
	if errors.Is(err, pgx.ErrNoRows) {
		return TablePicture{}, false, false, nil
	}
	return pic, active, err == nil, err
}

// pickWeighted draws one slot, each with probability weight / (the weights of
// all the slots together), from a number the draw takes in [0, total): the
// slots lie end to end along [0, total), each as long as its weight, and the
// number falls in exactly one. Weights need not add up to anything — 40, 20,
// 15, 10, 10, 5 or 3, 1, 2 alike — and a slot of weight 0 or less, which the
// schema forbids anyway, is never drawn.
func pickWeighted(slots []LuckyDrawSlot, pick func(n int64) (int64, error)) (LuckyDrawSlot, error) {
	var total int64
	for _, s := range slots {
		if s.weight > 0 {
			total += s.weight
		}
	}
	if total <= 0 {
		return LuckyDrawSlot{}, ErrLuckyDrawUnavailable
	}
	r, err := pick(total)
	if err != nil {
		return LuckyDrawSlot{}, err
	}
	if r < 0 || r >= total {
		return LuckyDrawSlot{}, fmt.Errorf("lucky draw: drew %d outside [0, %d)", r, total)
	}
	for _, s := range slots {
		if s.weight <= 0 {
			continue
		}
		if r < s.weight {
			return s, nil
		}
		r -= s.weight
	}
	// Unreachable: r < total, and the weights walked add up to total.
	return LuckyDrawSlot{}, fmt.Errorf("lucky draw: no slot for the draw")
}

// Spin is POST /api/lucky-draw/spin: one spin of the draw (code "" — the first
// active one) for one player, once per actionID, in one transaction:
//
//	SELECT chips FROM users WHERE id = $1 FOR UPDATE      lock the wallet (no row → unknown_user)
//	this key already spun? → the same answer again, Replayed, nothing granted
//	the draw, active                                      else ErrLuckyDrawUnavailable
//	its last spin + cooldown > now?                       → *LuckyDrawCooldown
//	its slots that can be won, drawn by weight            (crypto/rand)
//	the prize granted                                     chips through chip_ledger; the rest as deltas
//	INSERT user_lucky_draws                               the snapshot and the key
//
// All of it commits or none of it does: a prize that cannot be granted leaves
// no record of a spin, and a record that cannot be written takes the prize back
// out with it. The wallet lock serialises one player's spins, so two taps —
// with one key or two — cannot both pass the cooldown, and a retried request
// finds its first attempt's row and is answered from it. The key is
// LuckyDrawActionID(userID, actionID), UNIQUE in user_lucky_draws and, for a
// CHIPS prize, in chip_ledger: a commit whose answer was lost and whose retry
// somehow missed the look-up still collides on the index, and is answered as
// the replay it is.
//
// Nothing the caller says decides the prize: a client names a draw and a key,
// and the server draws. Lobby-only — the caller runs it under the player's
// seat lock (auth: WhileUnseated), because a CHIPS prize moves a wallet only
// the lobby may move (CLAUDE.md §5.1).
func (l *LuckyDraws) Spin(ctx context.Context, userID, code, actionID string) (*LuckyDrawSpin, error) {
	if actionID == "" {
		return nil, ErrLuckyDrawActionID
	}
	key := LuckyDrawActionID(userID, actionID)
	var out *LuckyDrawSpin
	err := l.db.WithTx(ctx, func(tx pgx.Tx) error {
		at := now(l.clock)
		chips, err := lockWallet(ctx, tx, userID)
		if err != nil {
			return err
		}
		if prior, err := l.replay(ctx, tx, userID, key, actionID, at); err != nil || prior != nil {
			out = prior
			return err
		}

		draw, err := loadDraw(ctx, tx, code)
		if err != nil {
			return err
		}
		if draw.CooldownMs > 0 {
			last, err := lastSpinAt(ctx, tx, userID, draw.id)
			if err != nil {
				return err
			}
			if last > 0 && at < last+draw.CooldownMs {
				return &LuckyDrawCooldown{NextSpinAt: last + draw.CooldownMs}
			}
		}

		slots, err := l.slots(ctx, tx, draw, userID)
		if err != nil {
			return err
		}
		slot, err := pickWeighted(slots, l.pick)
		if err != nil {
			return err
		}
		prize := LuckyDrawReward{
			Type:         slot.RewardType,
			Value:        slot.RewardValue,
			RefID:        slot.RewardRefID,
			Picture:      slot.Picture,
			TablePicture: slot.TablePicture,
		}
		alreadyOwned, err := grantLuckyPrize(ctx, tx, userID, key, chips, &prize, at)
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx,
			`INSERT INTO user_lucky_draws (user_id, lucky_draw_id, slot_id, reward_type, reward_value, reward_ref_id, action_id, created_at)
			 VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
			userID, draw.id, slot.id, prize.Type, prize.Value, prize.RefID, key, at); err != nil {
			return err
		}

		row, err := selectUser(ctx, tx, l.users.userFrom(), userID)
		if err != nil {
			return err
		}
		var next int64
		if draw.CooldownMs > 0 {
			next = at + draw.CooldownMs
		}
		out = &LuckyDrawSpin{
			ActionID:     actionID,
			SlotNumber:   slot.SlotNumber,
			Reward:       prize,
			AlreadyOwned: alreadyOwned,
			NextSpinAt:   next,
			User:         l.users.publicUser(row),
		}
		return nil
	})
	if err != nil && isUniqueViolationOn(err, "action_id") {
		// This key's first attempt committed in the meantime: answer from it.
		return l.replayNow(ctx, userID, key, actionID)
	}
	if err != nil {
		return nil, err
	}
	return out, nil
}

// replayNow answers a spin whose key is already recorded, outside any
// transaction.
func (l *LuckyDraws) replayNow(ctx context.Context, userID, key, actionID string) (*LuckyDrawSpin, error) {
	var out *LuckyDrawSpin
	err := l.db.WithTx(ctx, func(tx pgx.Tx) error {
		var err error
		out, err = l.replay(ctx, tx, userID, key, actionID, now(l.clock))
		return err
	})
	if err != nil {
		return nil, err
	}
	if out == nil {
		return nil, fmt.Errorf("lucky draw: spin %s collided but is not recorded", key)
	}
	return out, nil
}

// replay is the spin already recorded under key, answered again — the slot and
// the prize snapshot it recorded, the picture's catalogue row as it stands now,
// the account as it stands now — or nil when this key has not spun.
func (l *LuckyDraws) replay(ctx context.Context, q queryer, userID, key, actionID string, at int64) (*LuckyDrawSpin, error) {
	var (
		slotNumber         int16
		prize              LuckyDrawReward
		spunAt, cooldownMs int64
	)
	err := q.QueryRow(ctx,
		`SELECT s.slot_number, h.reward_type, h.reward_value, h.reward_ref_id, h.created_at, d.cooldown_ms
		   FROM user_lucky_draws h
		   JOIN lucky_draw_slots s ON s.id = h.slot_id
		   JOIN lucky_draws d ON d.id = h.lucky_draw_id
		  WHERE h.action_id = $1 AND h.user_id = $2`, key, userID).
		Scan(&slotNumber, &prize.Type, &prize.Value, &prize.RefID, &spunAt, &cooldownMs)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	// The picture as the catalogue has it now, for the client to draw; a row
	// since deleted leaves the snapshot alone.
	if id, ok := refID(prize.RefID); ok {
		switch prize.Type {
		case LuckyRewardProfilePicture:
			if pic, _, found, err := findPictureIn(ctx, q, userID, id, at); err != nil {
				return nil, err
			} else if found {
				prize.Picture = &pic
			}
		case LuckyRewardTablePicture:
			if pic, _, found, err := findTablePictureIn(ctx, q, userID, id, at); err != nil {
				return nil, err
			} else if found {
				prize.TablePicture = &pic
			}
		}
	}
	row, err := selectUser(ctx, q, l.users.userFrom(), userID)
	if err != nil {
		return nil, err
	}
	var next int64
	if cooldownMs > 0 && spunAt+cooldownMs > at {
		next = spunAt + cooldownMs
	}
	return &LuckyDrawSpin{
		ActionID:   actionID,
		SlotNumber: int(slotNumber),
		Reward:     prize,
		Replayed:   true,
		NextSpinAt: next,
		User:       l.users.publicUser(row),
	}, nil
}

// grantLuckyPrize gives the player the prize, inside the spin's transaction and
// under its wallet lock, and reports whether a picture prize was one they
// already had:
//
//   - CHIPS: the wallet and a chip_ledger row (reason lucky_draw, action_id the
//     spin's key), so SUM(chip_ledger.delta) == users.chips still holds — the
//     invariant every chip movement keeps (CLAUDE.md §5.1).
//   - DIAMOND, HAMMER, MISSILE: a delta on the users column, never ledgered, as
//     the daily bonus's hammer and a missile trade are; the spin's own row is
//     the receipt.
//   - NO_REWARD: nothing; the spin's row is all there is.
//   - PROFILE_PICTURE, TABLE_PICTURE: the ownership row a purchase would write,
//     for the term the shop would sell it for, counted from now — and NOT put
//     on: which picture a player wears, or lays on their table, stays their
//     choice. A picture already theirs (free, or bought and running) is left
//     exactly as it is: no second row — the key forbids one — and no longer
//     rental. A lapsed rental is renewed in place. `purchases` is not raised: a
//     prize is not a purchase, and a later purchase's ledger key only has to be
//     one the pair has not used.
func grantLuckyPrize(ctx context.Context, tx pgx.Tx, userID, key string, chips int64, prize *LuckyDrawReward, at int64) (bool, error) {
	amount := func() int64 {
		if prize.Value == nil {
			return 0
		}
		return *prize.Value
	}
	switch prize.Type {
	case LuckyRewardNone:
		return false, nil
	case LuckyRewardChips:
		balance := chips + amount()
		if _, err := tx.Exec(ctx,
			`UPDATE users SET chips = $2, updated_at = $3 WHERE id = $1`, userID, balance, at); err != nil {
			return false, err
		}
		return false, appendLedger(ctx, tx, userID, "", key, amount(), balance, game.LedgerReasonLuckyDraw, at)
	case LuckyRewardDiamond:
		_, err := tx.Exec(ctx, `UPDATE users SET diamond = diamond + $2, updated_at = $3 WHERE id = $1`, userID, amount(), at)
		return false, err
	case LuckyRewardHammer:
		_, err := tx.Exec(ctx, `UPDATE users SET hammer = hammer + $2, updated_at = $3 WHERE id = $1`, userID, amount(), at)
		return false, err
	case LuckyRewardMissile:
		_, err := tx.Exec(ctx, `UPDATE users SET missile = missile + $2, updated_at = $3 WHERE id = $1`, userID, amount(), at)
		return false, err
	case LuckyRewardProfilePicture:
		pic := prize.Picture
		if pic == nil {
			return false, fmt.Errorf("lucky draw: profile picture prize with no picture")
		}
		if pic.Free() || pic.Owned {
			return true, nil
		}
		expiresAt := rentalEnd(pic.DurationDays, pic.DurationHours, at)
		if _, err := tx.Exec(ctx,
			`INSERT INTO user_profile_pictures (user_id, profile_picture_id, acquired_at, expires_at, purchases)
			 VALUES ($1, $2, $3, $4, 1)
			 ON CONFLICT (user_id, profile_picture_id) DO UPDATE
			    SET acquired_at = EXCLUDED.acquired_at,
			        expires_at  = EXCLUDED.expires_at`,
			userID, pic.ID, at, expiresAt); err != nil {
			return false, err
		}
		pic.Owned, pic.ExpiresAt = true, expiresAt
		return false, nil
	case LuckyRewardTablePicture:
		pic := prize.TablePicture
		if pic == nil {
			return false, fmt.Errorf("lucky draw: table picture prize with no picture")
		}
		if pic.Free() || pic.Owned {
			return true, nil
		}
		expiresAt := rentalEnd(pic.DurationDays, pic.DurationHours, at)
		if _, err := tx.Exec(ctx,
			`INSERT INTO user_table_pictures (user_id, table_picture_id, acquired_at, expires_at, purchases)
			 VALUES ($1, $2, $3, $4, 1)
			 ON CONFLICT (user_id, table_picture_id) DO UPDATE
			    SET acquired_at = EXCLUDED.acquired_at,
			        expires_at  = EXCLUDED.expires_at`,
			userID, pic.ID, at, expiresAt); err != nil {
			return false, err
		}
		pic.Owned, pic.ExpiresAt = true, expiresAt
		return false, nil
	}
	// Unreachable: slots leaves out every prize it does not know.
	return false, fmt.Errorf("lucky draw: cannot grant a %q prize", prize.Type)
}

// rentalEnd is when a rental of days and hours taken at `at` runs out, or 0
// when it never does.
func rentalEnd(days, hours int, at int64) int64 {
	if term := int64(days)*DayMs + int64(hours)*HourMs; term > 0 {
		return at + term
	}
	return 0
}
