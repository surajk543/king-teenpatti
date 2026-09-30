package app

import (
	"context"
	"log/slog"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/config"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
)

// welcomeChipsCacheTTL is how long session:ready's welcomeChips is cached —
// the longest an owner's UPDATE of the welcome_rewards chips rows takes to
// reach it. The grant itself reads the rows on every new account, uncached.
const welcomeChipsCacheTTL = 15 * time.Second

// welcomeBootTimeout bounds the boot's write and read of the chips row.
const welcomeBootTimeout = 10 * time.Second

// ensureWelcome settles the welcome at boot, after the migrations (owner,
// 30 Sep 2026: what a new account is given comes from the welcome_rewards
// rows; the seed's chips row is 5 Lakh). In production the ROW decides: the
// chips row is written from WELCOME_CHIPS only when the table has none, and
// one WARN says so when WELCOME_CHIPS was set and a new account gets another
// figure. Outside production (tests, parity, a local run) WELCOME_CHIPS sets
// the chips row (Users.SetWelcomeChipsWins), logged at INFO.
// It answers the cache session:ready's welcomeChips is read through, holding
// the boot's figure. With no database it holds WELCOME_CHIPS and reads
// nothing; when the boot's write fails (logged) the cache holds WELCOME_CHIPS
// until its first read, and the store tries the row again before its first
// new account.
func ensureWelcome(cfg *config.Config, database *db.DB, users *db.Users, now func() time.Time, log *slog.Logger) *db.WelcomeChipsCache {
	if database == nil {
		return db.NewWelcomeChipsCache(nil, cfg.Game.WelcomeChips, true, welcomeChipsCacheTTL, now, log)
	}
	ctx, cancel := context.WithTimeout(context.Background(), welcomeBootTimeout)
	row, err := users.EnsureWelcomeChips(ctx)
	cancel()
	if err != nil {
		log.Error("welcome chips row not written; new accounts will try again", "error", err.Error(), "welcomeChips", cfg.Game.WelcomeChips)
		return db.NewWelcomeChipsCache(users.Welcome(), cfg.Game.WelcomeChips, false, welcomeChipsCacheTTL, now, log)
	}
	if row.Created {
		log.Info("welcome chips row written from WELCOME_CHIPS", "welcomeChips", row.Value, "active", row.Active)
	}
	if row.Set {
		log.Info("welcome chips row set from WELCOME_CHIPS (not production)", "welcomeChips", row.Value, "active", row.Active)
	}
	if cfg.Game.WelcomeChipsSet && row.Total != cfg.Game.WelcomeChips {
		log.Warn("WELCOME_CHIPS differs from the welcome_rewards chips; the rows win",
			"welcomeChipsEnv", cfg.Game.WelcomeChips,
			"chipsRow", row.Value,
			"chipsRowActive", row.Active,
			"chipsRowType", row.Type,
			"newAccountChips", row.Total,
			"hint", "UPDATE welcome_rewards SET reward_value = … WHERE code = 'chips' changes the welcome; in production WELCOME_CHIPS only writes the row when there is none")
	}
	return db.NewWelcomeChipsCache(users.Welcome(), row.Total, true, welcomeChipsCacheTTL, now, log)
}
