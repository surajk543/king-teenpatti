package db

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/metrics"
)

// MissilePack is one trade the missile store offers: Diamonds taken, Missiles
// given. The server's catalogue is the only source of either figure — a client
// names a pack, never an amount.
type MissilePack struct {
	ID       string
	Diamonds int64
	Missiles int64
}

// MissilePacks is the missile store's catalogue, by pack id (owner, 14 Sep
// 2026). Each pack is named by the missiles it gives, and the bigger packs cost
// less a missile: missiles_1 costs 10 diamonds, missiles_5 48, missiles_10 90
// and missiles_20 170. The owner re-priced the store several times that day
// (1 diamond = 2 missiles, a flat 5 diamonds a missile, then packs of 1, 6, 13
// and 30); only these four ids are on sale, whatever they cost before.
var MissilePacks = map[string]MissilePack{
	"missiles_1":  {ID: "missiles_1", Missiles: 1, Diamonds: 10},
	"missiles_5":  {ID: "missiles_5", Missiles: 5, Diamonds: 48},
	"missiles_10": {ID: "missiles_10", Missiles: 10, Diamonds: 90},
	"missiles_20": {ID: "missiles_20", Missiles: 20, Diamonds: 170},
}

// LookupMissilePack returns the pack with this id, or false.
func LookupMissilePack(id string) (MissilePack, bool) {
	pack, ok := MissilePacks[id]
	return pack, ok
}

// Missile store refusals. The HTTP layer turns them into their wire codes.
var (
	// ErrMissilePackUnknown: a pack id the catalogue does not hold.
	ErrMissilePackUnknown = errors.New("unknown_pack")
	// ErrMissileRequestID: an empty trade key.
	ErrMissileRequestID = errors.New("invalid_request_id")
	// ErrNotEnoughDiamonds: the wallet holds fewer diamonds than the pack costs.
	// Nothing was taken and no trade was recorded.
	ErrNotEnoughDiamonds = errors.New("not_enough_diamonds")
)

// MissileTrade is what TradeMissiles did.
type MissileTrade struct {
	// User is the account after the trade (or as it stands, on a replay).
	User *User
	// Charged is false when this request had already been traded: the request
	// still succeeded, but nothing moved this time.
	Charged bool
	// Diamonds is what this call took, 0 on a replay.
	Diamonds int64
	// Missiles is what this call gave, 0 on a replay.
	Missiles int64
}

// MissileTradeID is the key a trade is recorded under in missile_purchases:
// "<userId>:<requestId>". Scoped by the player, so one player's request id can
// never occupy — or replay — another's trade.
func MissileTradeID(userID, requestID string) string {
	return userID + ":" + requestID
}

// Missiles is the PostgreSQL game.MissileWallet — users.missile, charged one
// missile per missile fired — and the missile store that fills it from
// users.diamond (owner, 14 Sep 2026). The twin of Hammers.
//
// Kept apart from Ledger for the reason Hammers is: the Ledger is the chips and
// the three checkpoints of the money model (CLAUDE.md §5.1); missiles and
// diamonds are not chips, and neither a spend nor a trade writes chip_ledger.
type Missiles struct {
	db      *DB
	users   *Users
	metrics *metrics.Metrics // may be nil (tests)
	clock   func() time.Time
}

// NewMissiles builds the wallet and store. users builds the account a trade
// answers with; m may be nil (no observations); clock nil → time.Now.
func NewMissiles(d *DB, users *Users, m *metrics.Metrics, clock func() time.Time) *Missiles {
	return &Missiles{db: d, users: users, metrics: m, clock: clock}
}

var _ game.MissileWallet = (*Missiles)(nil)

// SpendMissile implements game.MissileWallet, in one transaction:
//
//	SELECT missile FROM users WHERE id = $1 FOR UPDATE              lock the wallet (no row → unknown_user)
//	INSERT INTO missile_spends (action_id, …) ON CONFLICT DO NOTHING
//	  nothing inserted → this key was already paid for: charge nothing, succeed
//	missile < cost → no_missiles, and the rollback takes the insert back out
//	UPDATE users SET missile = missile - cost RETURNING missile
//
// The insert comes before the balance check so that a retry of a spend that
// committed — its answer lost on the way back — succeeds even when that spend
// took the player's last missile: it has already been paid for. The wallet row
// is locked first, so two spends by one player queue, and the CHECK on
// users.missile is the last line against going below zero.
//
// Every error leaves as a *game.GameError: no_missiles as it is, anything else
// through Classify (persist_failed with the driver error as Cause), which the
// Table refuses the move with. A shortage is a refusal, not a failure, so it is
// not counted in game_db_transaction_errors_total.
func (m *Missiles) SpendMissile(ctx context.Context, req game.MissileSpend) (game.MissileSpendResult, error) {
	if req.UserID == "" || req.ActionID == "" {
		return game.MissileSpendResult{}, game.Errorf(game.CodePersistFailed, "missile spend needs a user and a key")
	}
	started := time.Now()
	var out game.MissileSpendResult
	err := m.db.WithTx(ctx, func(tx pgx.Tx) error {
		at := now(m.clock)
		var missile int64
		if err := tx.QueryRow(ctx,
			`SELECT missile FROM users WHERE id = $1 AND deleted_at = 0 FOR UPDATE`, req.UserID).Scan(&missile); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return game.Errorf(game.CodeUnknownUser, "unknown user %s", req.UserID)
			}
			return err
		}
		tag, err := tx.Exec(ctx,
			`INSERT INTO missile_spends (action_id, user_id, hand_id, created_at)
			 VALUES ($1, $2, $3, $4)
			 ON CONFLICT (action_id) DO NOTHING`,
			req.ActionID, req.UserID, req.HandID, at)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			out = game.MissileSpendResult{Remaining: missile, Charged: false}
			return nil
		}
		if missile < game.MissileCost {
			return game.NewGameError(game.CodeNoMissiles, game.MsgNoMissiles)
		}
		var remaining int64
		if err := tx.QueryRow(ctx,
			`UPDATE users SET missile = missile - $2, updated_at = $3 WHERE id = $1 RETURNING missile`,
			req.UserID, game.MissileCost, at).Scan(&remaining); err != nil {
			return err
		}
		out = game.MissileSpendResult{Remaining: remaining, Charged: true}
		return nil
	})

	if m.metrics != nil && m.metrics.DBTransactionDuration != nil {
		m.metrics.DBTransactionDuration.WithLabelValues(metrics.OpMissileSpend).Observe(time.Since(started).Seconds())
	}
	if err == nil {
		return out, nil
	}
	refusal := Classify(err)
	if refusal.Code != game.CodeNoMissiles && m.metrics != nil && m.metrics.DBTransactionErrors != nil {
		code := metrics.SafeLabel(refusal.Code, game.KnownLedgerCodes, metrics.OtherLabel)
		m.metrics.DBTransactionErrors.WithLabelValues(metrics.OpMissileSpend, code).Inc()
	}
	return game.MissileSpendResult{}, refusal
}

// TradeMissiles trades a pack's diamonds for its missiles, once per request
// (POST /api/store/missiles), in one transaction under the wallet lock:
//
//	SELECT diamond FROM users WHERE id = $1 FOR UPDATE        lock the wallet (no row → unknown_user)
//	INSERT missile_purchases (request_id, …) ON CONFLICT DO NOTHING
//	  nothing inserted → this request was already traded: Charged=false, nothing moves
//	diamond < pack.Diamonds → ErrNotEnoughDiamonds, and the rollback takes the row back out
//	UPDATE users SET diamond = diamond - d, missile = missile + n
//
// The key is MissileTradeID(userID, requestID). A replay answers with the
// account as it stands, not as the first call left it. Allowed at a table:
// nothing a seat holds is a diamond or a missile, so no seat lock is taken.
// The amounts come from the catalogue, never from the caller.
func (m *Missiles) TradeMissiles(ctx context.Context, userID, packID, requestID string) (*MissileTrade, error) {
	pack, ok := LookupMissilePack(packID)
	if !ok {
		return nil, ErrMissilePackUnknown
	}
	if requestID == "" {
		return nil, ErrMissileRequestID
	}
	key := MissileTradeID(userID, requestID)
	var out MissileTrade
	err := m.db.WithTx(ctx, func(tx pgx.Tx) error {
		at := now(m.clock)
		var diamond int64
		if err := tx.QueryRow(ctx,
			`SELECT diamond FROM users WHERE id = $1 AND deleted_at = 0 FOR UPDATE`, userID).Scan(&diamond); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return game.Errorf(game.CodeUnknownUser, "unknown user %s", userID)
			}
			return err
		}
		tag, err := tx.Exec(ctx,
			`INSERT INTO missile_purchases (request_id, user_id, diamonds, missiles, created_at)
			 VALUES ($1, $2, $3, $4, $5)
			 ON CONFLICT (request_id) DO NOTHING`,
			key, userID, pack.Diamonds, pack.Missiles, at)
		if err != nil {
			return err
		}
		if tag.RowsAffected() > 0 {
			if diamond < pack.Diamonds {
				return ErrNotEnoughDiamonds
			}
			if _, err := tx.Exec(ctx,
				`UPDATE users SET diamond = diamond - $2, missile = missile + $3, updated_at = $4 WHERE id = $1`,
				userID, pack.Diamonds, pack.Missiles, at); err != nil {
				return err
			}
			out.Charged, out.Diamonds, out.Missiles = true, pack.Diamonds, pack.Missiles
		}
		row, err := selectUser(ctx, tx, userID)
		if err != nil {
			return err
		}
		out.User = m.users.publicUser(row)
		return nil
	})
	if err != nil {
		return nil, err
	}
	return &out, nil
}
