package db

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"regexp"
	"strings"
	"sync"
	"time"
	"unicode"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
	"github.com/surajk543/king-teenpatti/go-server/internal/util"
)

// Provider values (users.provider CHECK).
const (
	ProviderGoogle   = "google"
	ProviderFacebook = "facebook"
	ProviderGuest    = "guest"
)

// User is the account as every client sees it (users.js publicUser) — the
// `user` of POST /api/auth/login, GET /api/auth/me, the purchase and profile
// responses and session:ready. Field order and names are the wire contract.
//
// There is no `rewards` key any more (owner, 30 Sep 2026: "Remove 24-hour
// daily reward, 4-hour bonus, and milestone reward"). It is left out, not sent
// empty: an installed app draws the three lobby reward chips only when
// user.rewards is present, so its absence is what takes them off the lobby of
// every build already in the store.
type User struct {
	ID          string  `json:"id"`
	Provider    string  `json:"provider"`
	DisplayName string  `json:"displayName"`
	Email       *string `json:"email"` // null for guests
	// AvatarURL is the asset_url of the catalogue picture the player is
	// wearing if they have chosen one, else avatar_url (a picture chosen
	// in-game wins over the provider's); null when neither.
	AvatarURL *string `json:"avatarUrl"`
	// ProviderAvatarURL is the raw avatar_url column — the photo Google or
	// Facebook gave us, which is a different thing from a chosen picture and
	// is what "use my social picture" falls back to.
	ProviderAvatarURL *string `json:"providerAvatarUrl"`
	// ActivePictureID is users.active_picture_id: the profile_pictures row
	// being worn, or null for none. Replaced avatarChoice, which carried the
	// bare "/profiles/bear.svg" path before the catalogue existed.
	ActivePictureID *int64 `json:"activePictureId"`
	// TablePicture is the table picture the player has laid (owner, 15 Sep
	// 2026; user_table_choice joined to table_pictures), or null for the table
	// as it comes. Resolved here, as AvatarURL is, so the felt can be drawn
	// from the account alone — before the catalogue has arrived, and for a row
	// since retired from it. Go only.
	TablePicture *LaidTablePicture `json:"tablePicture"`
	Chips        int64             `json:"chips"`
	// Diamond is the premium soft currency (users.diamond). Every account
	// starts with 2 (owner, 14 Sep 2026; it was 1). It is not
	// chip_ledger's business: the ledger backs the chips invariant, and
	// diamonds are not chips.
	Diamond int `json:"diamond"`
	// Hammer is users.hammer, the currency a Force Sideshow is paid in (owner,
	// 13 Sep 2026): 20 for every account (the column's default), and bought
	// in packs on Play. Like diamonds, never chip_ledger's business.
	Hammer int `json:"hammer"`
	// Missile is users.missile, what a missile costs (owner, 14 Sep 2026): 1
	// for every account (the column's default), and traded for diamonds in the missile store's packs (POST
	// /api/store/missiles). Never chip_ledger's business.
	Missile int `json:"missile"`
	// HandsPlayed … BiggestPot are the player's whole career: every bucket of
	// player_stats summed, the biggest pot the largest (StatsSheet.Totals) —
	// the keys and the meaning they had before the buckets existed.
	HandsPlayed   int   `json:"handsPlayed"`
	HandsWon      int   `json:"handsWon"`
	HandsLost     int   `json:"handsLost"`
	HandsLeftMid  int   `json:"handsLeftMid"`
	TotalWinnings int64 `json:"totalWinnings"`
	BiggestPot    int64 `json:"biggestPot"`
	// Stats is the same career per bucket — Teen Patti, Variation, Poker —
	// with the hands held and the variations played (Player stats v2, owner
	// 27 Sep 2026). Zeros, and no variations, for a player with no row.
	Stats       UserStats `json:"stats"`
	CreatedAt   int64     `json:"createdAt"`   // epoch ms
	LastLoginAt int64     `json:"lastLoginAt"` // epoch ms
	// Standing is the player's level and XP, the badges they hold and the
	// winning tax they pay (owner, 26–27 Sep 2026; levels.go) — on the wire
	// as user.playerLevel, user.badges and user.taxBps — resolved with every
	// account read. Always present: this object only ever goes to its own
	// player (login, me, session:ready and every answer that carries the
	// account), so nobody learns another player's level, XP or badges from
	// it.
	Standing
	// Disabled is NOT users.is_active: true when support has disabled the
	// account (owner, 26 Sep 2026). Negated so the zero value is an enabled
	// account — a User built anywhere but from a row (a test's fake store)
	// is never refused by accident. Never on the wire: a disabled account is
	// refused account_disabled before any user object is sent
	// (auth.RequireAuth, the socket handshake, every way into a seat).
	Disabled bool `json:"-"`
	// SessionVersion is user_sessions.version: how many times this account has
	// signed in since that table existed (0 with no row). Login adds one and
	// signs the new figure into the token it issues; a token carrying any
	// other figure belongs to a device another sign-in has replaced, and is
	// refused session_replaced (owner, 28 Sep 2026: one signed-in device per
	// account). Never on the wire.
	SessionVersion int64 `json:"-"`
}

// ErrAccountDisabled is a login for an account whose users.is_active is
// FALSE: UpsertFromProfile answers it before touching the row, and the login
// handler turns it into 403 account_disabled.
var ErrAccountDisabled = errors.New("account_disabled")

// LaidTablePicture is user.tablePicture on the wire: the table picture a
// player has laid, with both URLs so the client can draw the one its theme
// wants without a second request. AssetFormat is the catalogue's, for the
// loader (TablePicture.AssetFormat).
type LaidTablePicture struct {
	ID          int64  `json:"id"`
	DayURL      string `json:"dayUrl"`
	NightURL    string `json:"nightUrl"`
	AssetFormat string `json:"assetFormat"`
	// Currency and Cost are the catalogue row's, carried so a table can rank
	// the pictures its players have laid (game.TablePicture): diamonds over
	// hammers over coins, then the dearer.
	Currency string `json:"currency"`
	Cost     int64  `json:"cost"`
}

// ForTable is the laid picture as it goes onto a seat, tagged with the player
// who laid it; nil for nil.
func (l *LaidTablePicture) ForTable(userID string) *game.TablePicture {
	if l == nil {
		return nil
	}
	return &game.TablePicture{
		ID: l.ID, DayURL: l.DayURL, NightURL: l.NightURL, AssetFormat: l.AssetFormat,
		Currency: l.Currency, Cost: l.Cost, UserID: userID,
	}
}

// Player converts to the seat-level view the RoomManager needs — the winning
// tax the player pays among it (the lower of their level's and their badges',
// Standing.TaxBps), which their seat captures when they sit down.
func (u *User) Player() game.Player {
	return game.Player{ID: u.ID, DisplayName: u.DisplayName, AvatarURL: u.AvatarURL, TablePicture: u.TablePicture.ForTable(u.ID), Chips: u.Chips,
		TaxBps: u.TaxBps, Level: u.SeatLevel()}
}

// Profile is a verified login identity (auth providers → UpsertFromProfile).
type Profile struct {
	Provider       string // ProviderGoogle | ProviderFacebook | ProviderGuest
	ProviderUserID string // Google sub | Facebook id | sha256 of the device id
	DisplayName    string
	Email          *string
	AvatarURL      *string
	// IsBot marks this login as one of the resident bots (bot-play/), set by
	// the auth layer from the guest device id's namespace
	// (config.BotDevicePrefixes). It is written to users.is_bot (V1.0.0) and
	// is a LABEL for whoever queries the database — nothing in the game reads
	// it, and it never reaches a client.
	//
	// Only ever raises the flag: a login that is not recognised as a bot
	// leaves an existing account alone, so a human signing in can never clear
	// the mark on an account that earned it, and one bad guess cannot be
	// undone quietly by the next login.
	IsBot bool
}

// Display-name validation errors (users.js normalizeDisplayName throws
// Error(code)); auth.Handler maps them to 400 {error: code, message}.
var (
	ErrEmptyName   = errors.New("empty_name")
	ErrNameTooLong = errors.New("name_too_long")
	ErrInvalidName = errors.New("invalid_name")
)

// NamePattern is requirement 29's rule: starts with a letter or digit; then
// letters, digits, COMBINING MARKS and single spaces. \p{M} is essential —
// without it every Devanagari/Bengali/Gujarati/Gurmukhi name with a vowel
// sign is rejected.
var NamePattern = regexp.MustCompile(`^[\p{L}\p{N}][\p{L}\p{N}\p{M} ]*$`)

// NormalizeDisplayName trims, collapses internal whitespace to single spaces,
// then: empty → ErrEmptyName; more than maxLength UTF-16 code units →
// ErrNameTooLong (Node's `trimmed.length`, DECISIONS.md §4: an astral
// character counts 2); !NamePattern → ErrInvalidName. Whitespace is JS's `\s`
// class (isJSSpace), which is what both `trim()` and `/\s+/g` used.
func NormalizeDisplayName(raw string, maxLength int) (string, error) {
	trimmed := collapseJSSpace(strings.TrimFunc(raw, isJSSpace))
	if trimmed == "" {
		return "", ErrEmptyName
	}
	if utf16Length(trimmed) > maxLength {
		return "", ErrNameTooLong
	}
	if !NamePattern.MatchString(trimmed) {
		return "", ErrInvalidName
	}
	return trimmed, nil
}

// isJSSpace is JavaScript's `\s` (WhiteSpace + LineTerminator): Go's
// unicode.IsSpace plus U+FEFF (BOM), minus U+0085 (NEL), which JS does not
// count as whitespace (DECISIONS.md §4 "matching JS \s").
func isJSSpace(r rune) bool {
	if r == 0xFEFF {
		return true
	}
	if r == 0x85 {
		return false
	}
	return unicode.IsSpace(r)
}

// collapseJSSpace is `.replace(/\s+/g, ' ')`: every run of JS whitespace
// becomes one ASCII space.
func collapseJSSpace(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	inRun := false
	for _, r := range s {
		if isJSSpace(r) {
			if !inRun {
				b.WriteByte(' ')
				inRun = true
			}
			continue
		}
		inRun = false
		b.WriteRune(r)
	}
	return b.String()
}

// utf16Length is JavaScript's String.prototype.length: code points above
// U+FFFF are a surrogate pair and count 2.
func utf16Length(s string) int {
	n := 0
	for _, r := range s {
		if r >= 0x10000 {
			n += 2
		} else {
			n++
		}
	}
	return n
}

// Users is the account store (db/users.js).
type Users struct {
	db *DB
	// welcomeChips is WELCOME_CHIPS: NOT what a new account gets — the
	// welcome_rewards rows decide that (Welcome, owner 30 Sep 2026) — but the
	// figure the chips row is written with when the table has none
	// (EnsureWelcomeChips).
	welcomeChips int64
	clock        func() time.Time
	welcome      *Welcome
	logger       *slog.Logger // may be nil: a welcome reward left out is then not reported

	// chipsMu guards chipsReady: whether this store has made sure the chips
	// row exists (EnsureWelcomeChips), which it does once, before the first
	// account it creates.
	chipsMu    sync.Mutex
	chipsReady bool
}

// NewUsers builds the store. welcomeChips is config.Game.WelcomeChips
// (requirement 5): what the welcome_rewards chips row is written with when a
// database has none — app.New does it at boot, and the store itself before the
// first account it creates, so a store built without the app (a test, a tool)
// starts accounts where it was told to. What a new account is given is the
// rows' (SignIn). clock nil → time.Now.
func NewUsers(d *DB, welcomeChips int64, clock func() time.Time) *Users {
	return &Users{db: d, welcomeChips: welcomeChips, clock: clock, welcome: NewWelcome(d, clock)}
}

// SetLogger names the logger a welcome reward left out is reported on (`welcome
// reward left out`, WARN). Call it before the store is used.
func (u *Users) SetLogger(logger *slog.Logger) { u.logger = logger }

// Welcome is the welcome_rewards store this one grants from.
func (u *Users) Welcome() *Welcome { return u.welcome }

// EnsureWelcomeChips writes the welcome_rewards chips row from WELCOME_CHIPS
// when the table has none (Welcome.EnsureChipsRow) and reports the row as it
// stands. app.New calls it at boot, after the migrations, and compares the
// row with WELCOME_CHIPS; SignIn calls it before the store's first new
// account (once per store; a failure is tried again next time).
func (u *Users) EnsureWelcomeChips(ctx context.Context) (WelcomeChipsRow, error) {
	u.chipsMu.Lock()
	defer u.chipsMu.Unlock()
	row, err := u.welcome.EnsureChipsRow(ctx, u.welcomeChips)
	if err == nil {
		u.chipsReady = true
	}
	return row, err
}

// ensureWelcomeChipsOnce is EnsureWelcomeChips the first time only.
func (u *Users) ensureWelcomeChipsOnce(ctx context.Context) error {
	u.chipsMu.Lock()
	defer u.chipsMu.Unlock()
	if u.chipsReady {
		return nil
	}
	if _, err := u.welcome.EnsureChipsRow(ctx, u.welcomeChips); err != nil {
		return err
	}
	u.chipsReady = true
	return nil
}

// queryer is the slice of *pgxpool.Pool and pgx.Tx the store reads through,
// so publicUser can be built inside and outside a transaction alike.
type queryer interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
}

// userColumns is every users column, in DDL order (hammer and missile beside
// diamond, where the baseline declares them; a database built by older scripts
// has them at the end of the table), so a row scans into
// userRow without depending on `SELECT *` column ordering, followed by the
// asset_url of the catalogue picture the player is wearing and the table
// picture they have laid (user_table_choice → table_pictures; owner, 15 Sep
// 2026). Nothing is read from user_milestones since the three lobby rewards
// were removed (owner, 30 Sep 2026); the table is kept for a rollback only.
// The gameplay statistics come from player_stats and player_variation_stats
// (Player stats v2, 27 Sep 2026: a row per bucket, and one per variation) as
// statsColumns' two JSON arrays, '[]' for a player with none; the six counters
// the user object has always carried are their sum (StatsSheet.Totals), and
// player_stats.hands_left is what the wire still calls handsLeftMid.
// Qualified with the `u` alias because every read now goes through userFrom's
// joins.
const userColumns = `u.id, u.provider, u.provider_user_id, u.display_name, u.email, u.avatar_url, u.chips, u.diamond, u.hammer, u.missile,
       ` + statsColumns + `,
       u.active_picture_id, u.created_at, u.updated_at, u.last_login_at, u.is_active,
       COALESCE(us.version, 0),
       ap.asset_url,
       tp.id, tp.day_asset_url, tp.night_asset_url, tp.asset_format, tp.currency, tp.cost,
       ` + playerLevelColumns

// userFromAt is the FROM clause of every account read: it joins the picture
// the player is wearing so publicUser can resolve avatarUrl without a second
// round trip, the table picture they have laid for the same reason, and their
// user_sessions row, the sign-in a valid token must carry. LEFT, because most
// players wear nothing and a new one has signed in no session yet, and every
// one of them must still come back from these queries. (Their statistics are
// statsColumns' subqueries, not a join: a player has a row per bucket.)
//
// The laid table picture joins only while it may still be laid — a FREE row,
// or a PREMIUM one whose rental has not run out at this instant (%d, epoch
// ms, baked in as tableOwnedJoin bakes it) — so a lapsed rental reads as no
// picture the moment it lapses, whether or not a sweep (TablePictures
// .ExpireLapsed) has deleted the choice row yet. The account is what every
// seat is built from (User.Player → RoomManagerOptions.LoadPlayer), and it is
// the whole table that shows a laid picture, so a stale one here would go on
// dressing every viewer's felt past the term the chips bought.
//
// A locking read adds `FOR UPDATE OF u`: the bare form would try to lock the
// catalogue row too, and two players buying the same picture would queue behind
// each other for no reason.
//
// The player's level, XP, badges and winning-tax rate come through
// playerLevelJoins (levels.go), the one statement of the rule (owner,
// 26–27 Sep 2026), at the same instant (%[1]d) as the table picture's join.
const userFromAt = ` FROM users u LEFT JOIN profile_pictures ap ON ap.id = u.active_picture_id
  LEFT JOIN user_sessions us ON us.user_id = u.id
  LEFT JOIN user_table_choice tc ON tc.user_id = u.id
  LEFT JOIN table_pictures tp ON tp.id = tc.table_picture_id
   AND (tp.type = 'FREE' OR EXISTS (
        SELECT 1 FROM user_table_pictures o
         WHERE o.user_id = u.id AND o.table_picture_id = tp.id
           AND (o.expires_at = 0 OR o.expires_at > %[1]d))) ` + playerLevelJoins

// userFrom is userFromAt with this instant baked in.
func (u *Users) userFrom() string {
	return fmt.Sprintf(userFromAt, now(u.clock))
}

// userRow is one users row as stored (snake_case columns).
type userRow struct {
	id, provider, providerUserID, displayName string
	email, avatarURL                          *string
	// activePictureID is the catalogue row worn; pictureAssetURL is that
	// row's asset_url, carried along by userFromAt's join.
	activePictureID *int64
	pictureAssetURL *string
	// tablePictureID and the three beside it are the table picture laid,
	// carried by userFromAt's joins; all nil for the table as it comes, and
	// for a rental that has run out.
	tablePictureID             *int64
	tableDayURL, tableNightURL *string
	tableAssetFormat           *string
	tableCurrency              *string
	tableCost                  *int64
	chips                      int64
	diamond                    int
	hammer                     int
	missile                    int
	// stats is the player's statistics (player_stats and
	// player_variation_stats; zeros with no row), and handsPlayed their sum of
	// hands_played.
	stats                             StatsSheet
	handsPlayed                       int
	createdAt, updatedAt, lastLoginAt int64
	// active is users.is_active: FALSE disables the account.
	active bool
	// sessionVersion is user_sessions.version, 0 with no row.
	sessionVersion int64
	// level is the player's level, XP, window and badges (playerLevelJoins).
	level levelRow
}

// scanUser scans one row selected with userColumns; pgx.ErrNoRows → nil, nil.
func scanUser(row pgx.Row) (*userRow, error) {
	var r userRow
	var buckets, variations string
	targets := []any{&r.id, &r.provider, &r.providerUserID, &r.displayName, &r.email, &r.avatarURL, &r.chips, &r.diamond, &r.hammer, &r.missile,
		&buckets, &variations,
		&r.activePictureID, &r.createdAt, &r.updatedAt, &r.lastLoginAt, &r.active,
		&r.sessionVersion,
		&r.pictureAssetURL,
		&r.tablePictureID, &r.tableDayURL, &r.tableNightURL, &r.tableAssetFormat, &r.tableCurrency, &r.tableCost}
	err := row.Scan(append(targets, r.level.targets()...)...)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if r.stats, err = parseStatsSheet(buckets, variations); err != nil {
		return nil, err
	}
	r.handsPlayed = int(r.stats.Totals().HandsPlayed)
	return &r, nil
}

// selectUser is Node's selectUser(client, id): SELECT … FROM users WHERE id = $1.
//
// A deleted account is invisible here, which is what makes deletion take
// effect immediately: a JWT is valid for 30 days, so a token minted before
// the account was deleted would otherwise keep working until it expired.
// Every authenticated path — RequireAuth and the socket handshake both — ends
// up in this query, and gets "unknown user" instead.
//
// from is the FROM clause with the caller's instant baked in (Users.userFrom),
// which is what decides whether a laid rental still reads as laid.
func selectUser(ctx context.Context, q queryer, from, id string) (*userRow, error) {
	return scanUser(q.QueryRow(ctx,
		`SELECT `+userColumns+from+` WHERE u.id = $1 AND u.deleted_at = 0`, id))
}

// publicUser is users.js publicUser(row): the wire object. The standing (a
// badge's time left, the rate it sets) is evaluated now, at serialisation
// time, so two reads of one row can differ.
func (u *Users) publicUser(r *userRow) *User {
	if r == nil {
		return nil
	}
	// The career totals are every bucket summed. Those counters reach
	// PostgreSQL by the stats flusher's group commit, so they trail play by up
	// to one STATS_FLUSH_MS (10 s by default). Accepted (owner, 27 Sep 2026).
	totals := r.stats.Totals()
	// A picture chosen in-game wins over the one the provider gave us. The
	// choice is a catalogue id now, so what goes on the wire is that row's
	// asset_url; a row that has since been deleted leaves the join null and
	// falls through to the provider picture rather than to a broken link.
	avatarURL := r.avatarURL
	if r.pictureAssetURL != nil && *r.pictureAssetURL != "" {
		avatarURL = r.pictureAssetURL
	}
	// The table picture laid, when the join found its catalogue row; a choice
	// whose row has gone (the cascade is on the way) reads as no table.
	var table *LaidTablePicture
	if r.tablePictureID != nil && r.tableDayURL != nil && r.tableNightURL != nil {
		table = &LaidTablePicture{ID: *r.tablePictureID, DayURL: *r.tableDayURL, NightURL: *r.tableNightURL}
		if r.tableAssetFormat != nil {
			table.AssetFormat = *r.tableAssetFormat
		}
		if r.tableCurrency != nil {
			table.Currency = *r.tableCurrency
		}
		if r.tableCost != nil {
			table.Cost = *r.tableCost
		}
	}
	return &User{
		ID:                r.id,
		Provider:          r.provider,
		DisplayName:       r.displayName,
		Email:             r.email,
		AvatarURL:         avatarURL,
		ProviderAvatarURL: r.avatarURL,
		ActivePictureID:   r.activePictureID,
		TablePicture:      table,
		Chips:             r.chips,
		Diamond:           r.diamond,
		Hammer:            r.hammer,
		Missile:           r.missile,
		HandsPlayed:       r.handsPlayed,
		HandsWon:          int(totals.HandsWon),
		HandsLost:         int(totals.HandsLost),
		HandsLeftMid:      int(totals.HandsLeft),
		TotalWinnings:     totals.TotalWinnings,
		BiggestPot:        totals.BiggestPot,
		Stats:             r.stats.Wire(),
		CreatedAt:         r.createdAt,
		LastLoginAt:       r.lastLoginAt,
		Standing:          r.level.standing(now(u.clock)),
		Disabled:          !r.active,
		// A User built anywhere but from a row carries 0, which is also what a
		// token from before sessions were counted carries.
		SessionVersion: r.sessionVersion,
	}
}

// FindByID returns the user or nil, nil when absent (SELECT * FROM users
// WHERE id = $1). The socket layer calls this on EVERY connect and every
// join, so keep it one indexed query.
func (u *Users) FindByID(ctx context.Context, id string) (*User, error) {
	row, err := selectUser(ctx, u.db.Pool, u.userFrom(), id)
	if err != nil {
		return nil, err
	}
	return u.publicUser(row), nil
}

// FindByProvider looks up by (provider, provider_user_id); nil, nil when absent.
func (u *Users) FindByProvider(ctx context.Context, provider, providerUserID string) (*User, error) {
	row, err := scanUser(u.db.Pool.QueryRow(ctx,
		`SELECT `+userColumns+u.userFrom()+` WHERE u.provider = $1 AND u.provider_user_id = $2
		   AND u.deleted_at = 0`,
		provider, providerUserID))
	if err != nil {
		return nil, err
	}
	return u.publicUser(row), nil
}

// upsertAttempts bounds the retry of a first login that lost the race to an
// identical concurrent first login (DECISIONS.md §5).
const upsertAttempts = 5

// SignIn finds or creates the account behind a verified profile
// (requirements 1, 2, 5, 7). One transaction: SELECT … FOR UPDATE by
// provider identity; if found UPDATE email = COALESCE($1, email), avatar_url
// = COALESCE($2, avatar_url), updated_at = last_login_at = now → IsNew false,
// no Welcome. Else the account is created and WELCOMED (owner, 30 Sep 2026:
// "new account will get how much coins, hammers, diamonds, profile_picture,
// emoji — this data should come from database, user might get some or all
// rewards"): every ACTIVE welcome_rewards row is read (planWelcome — no cache,
// so an owner's UPDATE applies to this very account), the users row is
// INSERTed with its chips, diamond, hammer and missile set EXPLICITLY to the
// rows' totals (0 where no row gives any — the column DEFAULTs no longer
// decide), the welcome ledger row follows (hand_id NULL, action_id NULL, delta
// = balance = the chips, reason welcome_bonus, written even at 0), and the
// catalogue items become the account's (the ownership rows a purchase writes,
// never worn or laid) → IsNew true, Welcome what was given. A row that cannot
// be granted is left out with one WARN `welcome reward left out` and never
// refuses the login.
//
// Two simultaneous first logins for one identity both see no row (FOR UPDATE
// locks nothing when there is nothing to lock) and both INSERT; the loser's
// unique violation on (provider, provider_user_id) rolls its whole
// transaction back — its grant with it — and the transaction is retried,
// which now finds the winner's row and takes the UPDATE path — so exactly one
// account, one welcome_bonus row and one grant ever exist (DECISIONS.md §5;
// Node answered that request with HTTP 500).
//
// The profile's display name is used ONLY for a new account (24 Sep 2026,
// owner's "fix all bugs"; requirement 29). Node overwrote display_name with
// the provider's name on every login, so a name the player chose in the game
// was clobbered the next time they signed in — for a guest, by the generated
// "Guest8D049" whenever the login screen's name field was left empty. Once the
// account exists the name is the player's: POST /api/profile/name is the one
// way to change it. Email and the provider photo still refresh.
//
// Every login, new account or not, starts a new session (startSession): the
// returned user's SessionVersion is the one its token must carry, and any
// device signed in before it is signed out (owner, 28 Sep 2026).
func (u *Users) SignIn(ctx context.Context, p Profile) (*SignIn, error) {
	// Captured before BEGIN, as Node does (`const timestamp = now()`).
	timestamp := now(u.clock)

	// The chips row, from WELCOME_CHIPS, before the first account this store
	// creates (app.New has already done it at boot; this is a no-op there).
	if err := u.ensureWelcomeChipsOnce(ctx); err != nil {
		return nil, err
	}

	for attempt := 1; ; attempt++ {
		result, leftOut, err := u.upsertOnce(ctx, p, timestamp)
		if err == nil {
			if u.logger != nil {
				for _, l := range leftOut {
					u.logger.Warn("welcome reward left out",
						"code", l.Code, "rewardType", l.Type, "reason", l.Reason, "userId", result.User.ID)
				}
			}
			return result, nil
		}
		if attempt < upsertAttempts && isUniqueViolationOn(err, "provider_user_id") {
			continue
		}
		return nil, err
	}
}

// UpsertFromProfile is SignIn without the welcome: the account and whether
// this login created it.
func (u *Users) UpsertFromProfile(ctx context.Context, p Profile) (user *User, isNew bool, err error) {
	result, err := u.SignIn(ctx, p)
	if err != nil {
		return nil, false, err
	}
	return result.User, result.IsNew, nil
}

// upsertOnce is one attempt at SignIn's transaction; it reports the welcome
// rewards a new account was not given.
func (u *Users) upsertOnce(ctx context.Context, p Profile, timestamp int64) (result *SignIn, leftOut []WelcomeLeftOut, err error) {
	err = u.db.WithTx(ctx, func(tx pgx.Tx) error {
		existing, err := scanUser(tx.QueryRow(ctx,
			`SELECT `+userColumns+u.userFrom()+` WHERE u.provider = $1 AND u.provider_user_id = $2 FOR UPDATE OF u`,
			p.Provider, p.ProviderUserID))
		if err != nil {
			return err
		}

		if existing != nil {
			// A disabled account is refused here, before the row is touched:
			// a login attempt must not refresh last_login_at or the provider
			// details of an account support has switched off.
			if !existing.active {
				return ErrAccountDisabled
			}
			if _, err := tx.Exec(ctx, `UPDATE users
            SET email         = COALESCE($1, email),
                avatar_url    = COALESCE($2, avatar_url),
                -- OR, never assignment: a login that is not recognised as a
                -- bot leaves the mark alone. The fleet rotates a broke bot
                -- into a fresh identity and the prefix follows it, so this is
                -- belt and braces — but an account wrongly cleared would be
                -- indistinguishable from a person for ever after, and the
                -- whole value of the column is that it can be trusted.
                is_bot        = users.is_bot OR $3,
                updated_at    = $4,
                last_login_at = $4
          WHERE id = $5`,
				p.Email, p.AvatarURL, p.IsBot, timestamp, existing.id); err != nil {
				return err
			}
			if err := startSession(ctx, tx, existing.id, timestamp); err != nil {
				return err
			}
			row, err := selectUser(ctx, tx, u.userFrom(), existing.id)
			if err != nil {
				return err
			}
			result, leftOut = &SignIn{User: u.publicUser(row)}, nil
			return nil
		}

		// What this account is welcomed with, read now: no cache.
		plan, err := planWelcome(ctx, tx, timestamp, true)
		if err != nil {
			return err
		}

		id := util.UUID()
		if _, err := tx.Exec(ctx, `INSERT INTO users (id, provider, provider_user_id, display_name, email, avatar_url,
                          chips, diamond, hammer, missile, is_bot, created_at, updated_at, last_login_at)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $12, $12)`,
			id, p.Provider, p.ProviderUserID, p.DisplayName, p.Email, p.AvatarURL,
			plan.chips, plan.diamonds, plan.hammers, plan.missiles, p.IsBot, timestamp); err != nil {
			return err
		}

		// The insert and the welcome-grant ledger row go in one transaction
		// so a crash can never leave an account whose balance is not backed
		// by the ledger. Written even when the welcome holds no chips.
		if err := appendLedger(ctx, tx, id, "", "", plan.chips, plan.chips, game.LedgerReasonWelcomeBonus, timestamp); err != nil {
			return err
		}
		grant, err := plan.grant(ctx, tx, id, timestamp)
		if err != nil {
			return err
		}
		if err := startSession(ctx, tx, id, timestamp); err != nil {
			return err
		}

		row, err := selectUser(ctx, tx, u.userFrom(), id)
		if err != nil {
			return err
		}
		result, leftOut = &SignIn{User: u.publicUser(row), IsNew: true, Welcome: grant}, plan.leftOut
		return nil
	})
	if err != nil {
		return nil, nil, err
	}
	return result, leftOut, nil
}

// startSession counts one more sign-in for the account (user_sessions; owner,
// 28 Sep 2026: one signed-in device per account), inside the login's
// transaction and under its row lock, so two logins at once number themselves
// one after the other. The read that follows carries the new figure, which
// the login signs into its token; every token signed before it is refused
// session_replaced from this commit on.
func startSession(ctx context.Context, tx pgx.Tx, userID string, timestamp int64) error {
	_, err := tx.Exec(ctx, `INSERT INTO user_sessions (user_id, version, updated_at) VALUES ($1, 1, $2)
	    ON CONFLICT (user_id) DO UPDATE SET version = user_sessions.version + 1, updated_at = $2`,
		userID, timestamp)
	return err
}

// ApplyChipDelta adjusts a wallet with a matching ledger row, row locked,
// refusing a negative result (applyChipDelta). Not used by gameplay — grants,
// tooling and corrections only. Returns the new balance. Errors are plain
// errors, not GameErrors, as in Node: "unknown user <id>" / "insufficient
// chips for <id>". handID/actionID "" → NULL.
func (u *Users) ApplyChipDelta(ctx context.Context, userID string, delta int64, reason, handID, actionID string) (int64, error) {
	var balance int64
	err := u.db.WithTx(ctx, func(tx pgx.Tx) error {
		var chips int64
		err := tx.QueryRow(ctx, `SELECT chips FROM users WHERE id = $1 FOR UPDATE`, userID).Scan(&chips)
		if errors.Is(err, pgx.ErrNoRows) {
			return fmt.Errorf("unknown user %s", userID)
		}
		if err != nil {
			return err
		}

		balance = chips + delta
		if balance < 0 {
			return fmt.Errorf("insufficient chips for %s", userID)
		}

		timestamp := now(u.clock) // Node captures it after the lock here
		if _, err := tx.Exec(ctx, `UPDATE users SET chips = $1, updated_at = $2 WHERE id = $3`, balance, timestamp, userID); err != nil {
			return err
		}
		return appendLedger(ctx, tx, userID, handID, actionID, delta, balance, reason, timestamp)
	})
	if err != nil {
		return 0, err
	}
	return balance, nil
}

// SetDisplayName updates display_name (already normalised) and returns the
// fresh user. A plain UPDATE outside any transaction, then FindByID (Node).
func (u *Users) SetDisplayName(ctx context.Context, userID, displayName string) (*User, error) {
	if _, err := u.db.Pool.Exec(ctx, `UPDATE users SET display_name = $1, updated_at = $2 WHERE id = $3`,
		displayName, now(u.clock), userID); err != nil {
		return nil, err
	}
	return u.FindByID(ctx, userID)
}

// SetActivePicture points users.active_picture_id at a catalogue row (or nil
// to take the picture off and fall back to the provider photo) and returns the
// fresh user.
//
// It does NOT check that the player owns the picture — that is the caller's
// job, because the refusal has to reach the client as a message rather than as
// a constraint violation. The foreign key is still the backstop: an id that is
// not in the catalogue is refused by the database, not stored and drawn as a
// broken image later.
func (u *Users) SetActivePicture(ctx context.Context, userID string, pictureID *int64) (*User, error) {
	if _, err := u.db.Pool.Exec(ctx, `UPDATE users SET active_picture_id = $1, updated_at = $2 WHERE id = $3`,
		pictureID, now(u.clock), userID); err != nil {
		return nil, err
	}
	return u.FindByID(ctx, userID)
}

// DeletedDisplayName replaces the name on an account the player has deleted.
// Ledger rows keep pointing at the row, so it needs to read as gone rather
// than as blank.
const DeletedDisplayName = "Deleted player"

// DeleteAccount erases the person behind an account at their own request
// (Google Play requires apps that create accounts to offer this).
//
// It pseudonymises rather than deletes, and the schema forces that:
// chip_ledger.user_id REFERENCES users (id) ON DELETE CASCADE, so removing
// the row would silently take the money audit with it — the one record that
// is append-only precisely because it must never be lost. The row therefore
// stays, emptied of anything that identifies anyone. The users_no_delete
// trigger (§7.3) refuses a real DELETE from every caller in any case.
//
// Erased: display name, email, the provider photo, the worn picture, the laid
// table picture, the friendships (both directions; pending friend requests
// either way are CANCELLED — Friends V1), and the
// provider identity. Clearing the identity is what frees (provider,
// provider_user_id) for reuse, so the same device signing in afterwards gets
// a NEW account with a fresh welcome bonus instead of being handed the
// deleted one back.
//
// The wallet is emptied through a ledger row rather than by writing chips = 0
// directly, because SUM(chip_ledger.delta) == users.chips is the invariant
// the entire money model is audited against (CLAUDE.md §7.3). Zeroing the
// column on its own would break it for every account ever deleted, and the
// append-only trigger means it could never be repaired in place.
//
// Chips leave the economy here. That is the right answer: so has the player.
func (u *Users) DeleteAccount(ctx context.Context, userID string) error {
	return u.db.WithTx(ctx, func(tx pgx.Tx) error {
		var chips int64
		err := tx.QueryRow(ctx,
			`SELECT chips FROM users WHERE id = $1 AND deleted_at = 0 FOR UPDATE`, userID).Scan(&chips)
		if errors.Is(err, pgx.ErrNoRows) {
			// Already deleted, or never existed. Either way there is nothing
			// left to erase, and saying so is not an error the caller can act
			// on differently.
			return nil
		}
		if err != nil {
			return err
		}
		timestamp := now(u.clock)
		if chips > 0 {
			// action_id is unique per account, so a retried delete cannot
			// write the drop twice — the second attempt fails the unique
			// index rather than double-counting. It cannot fire in practice
			// (the account is invisible by then) but the ledger's rule is
			// that every row carries its own idempotency.
			if err := appendLedger(ctx, tx, userID, "", "delete:"+userID,
				-chips, 0, game.LedgerReasonAccountDeleted, timestamp); err != nil {
				return err
			}
		}
		_, err = tx.Exec(ctx, `
			UPDATE users
			   SET chips             = 0,
			       display_name      = $1,
			       email             = NULL,
			       avatar_url        = NULL,
			       active_picture_id = NULL,
			       provider_user_id  = $2,
			       deleted_at        = $3,
			       updated_at        = $3
			 WHERE id = $4`,
			DeletedDisplayName, "deleted:"+util.UUID(), timestamp, userID)
		if err != nil {
			return err
		}
		// The laid table picture is active_picture_id's twin, kept in its own
		// table (user_table_choice, V1.0.0's TABLE PICTURES); it comes off
		// here as the face does. users rows are never deleted, so the row's
		// ON DELETE CASCADE would never do it.
		if _, err = tx.Exec(ctx, `DELETE FROM user_table_choice WHERE user_id = $1`, userID); err != nil {
			return err
		}
		// The badges given to the account (user_badges, V1.0.0's PLAYER
		// LEVELS) go with it, for the same reason: the row's cascade never
		// fires. A deleted account holds nothing and pays nobody's rate.
		if _, err = tx.Exec(ctx, `DELETE FROM user_badges WHERE user_id = $1`, userID); err != nil {
			return err
		}
		// The statistics (Player stats v2): the player's rows go, per bucket
		// and per variation — the same cascade reason. Counters still pending
		// in the live store are dropped by the app, best effort, and a flush
		// of any that remain finds the account deleted and adds nothing.
		if err := deleteStats(ctx, tx, userID); err != nil {
			return err
		}
		// The social graph (Friends V1): nobody keeps a deleted account as a
		// friend, and nothing is left pending with it — the friendships go,
		// both directions, and the pending requests either way are
		// CANCELLED. The same cascade reason as above: it would never fire.
		return forgetFriends(ctx, tx, userID, timestamp)
	})
}
