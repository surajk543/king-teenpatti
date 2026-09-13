package db_test

import (
	"context"
	"fmt"
	"os/exec"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
	"github.com/surajk543/king-teenpatti/go-server/internal/db/dbtest"
)

// Butterfly Flapping moved from a file this server served to Drive (13 Sep
// 2026), and V1.0.2 — a script production had already run — carries the move,
// because no later script could (its header says why). These tests hold it to
// what that edit promises on every kind of database it meets: exactly one
// 'Butterfly Flapping' row, at the Drive URL, on the id it already had, with
// every purchase and every wearer intact, and nothing further changed by
// another boot.

const (
	butterflyOldURL   = "/profiles/butterfly-flapping.json"
	butterflyDriveURL = "https://drive.google.com/uc?export=download&id=19mQ9PjStBJUoFyThaSe97fEcfzARw_Ar"
	day               = 24 * time.Hour
)

// v130Tag is the release production ran the old V1.0.2 under, and
// v130Migrations the scripts it shipped, in version order. A tag never moves,
// so the list is exact rather than read from the tree.
const v130Tag = "refs/tags/go-server/v1.3.0"

var v130Migrations = []string{
	"V1.0.0__baseline.sql",
	"V1.0.1__seed_profile_pictures.sql",
	"V1.0.2__seed_animated_pictures.sql",
	"V1.0.3__diamond_purchases.sql",
}

// A fresh database never sees the old URL: it is seeded straight at Drive,
// once, and a restart leaves that row exactly as it was.
func TestAFreshDatabaseSeedsButterflyFlappingOnceAtItsDriveURL(t *testing.T) {
	schema, conn := butterflySchema(t)
	bootNow(t, schema)

	rows := butterflyRows(t, conn)
	if len(rows) != 1 || rows[0].URL != butterflyDriveURL {
		t.Fatalf("a fresh database holds %+v, want one row at %s", rows, butterflyDriveURL)
	}
	var format, currency string
	var cost, sortOrder int64
	if err := conn.QueryRow(context.Background(),
		`SELECT asset_format, currency, cost, sort_order FROM profile_pictures WHERE id = $1`, rows[0].ID).
		Scan(&format, &currency, &cost, &sortOrder); err != nil {
		t.Fatal(err)
	}
	if format != "LOTTIE" || currency != "DIAMOND" || cost != 4 || sortOrder != 170 {
		t.Fatalf("seeded as %s/%s cost %d sort %d, want LOTTIE/DIAMOND cost 4 sort 170", format, currency, cost, sortOrder)
	}
	assertBootsChangeNothing(t, schema, conn)
	if again := butterflyRows(t, conn); len(again) != 1 || again[0] != rows[0] {
		t.Fatalf("after two more boots: %+v, want %+v", again, rows[0])
	}
}

// Production as go-server/v1.3.0 left it: the row at the served path, bought
// and worn. The first boot of this build moves it to Drive in place; the
// second changes nothing.
func TestAV130DatabaseMovesButterflyFlappingToDriveKeepingItsIDBuyersAndWearers(t *testing.T) {
	schema, conn := butterflySchema(t)
	buildAtV130(t, conn)

	before := butterflyRows(t, conn)
	if len(before) != 1 || before[0].URL != butterflyOldURL {
		t.Fatalf("v1.3.0 should leave one row at %s, found %+v", butterflyOldURL, before)
	}
	id := before[0].ID
	others := catalogueExcept(t, conn, id)

	start := nowMs()
	wearer, owner := "v130-wearer", "v130-owner"
	addPlayer(t, conn, wearer)
	addPlayer(t, conn, owner)
	own(t, conn, wearer, id, start, start+(50*day).Milliseconds(), 1)
	wear(t, conn, wearer, id)
	own(t, conn, owner, id, start-(3*day).Milliseconds(), start+(97*day).Milliseconds(), 2)
	ownedBefore := ownership(t, conn, wearer) + ownership(t, conn, owner)

	d := bootNow(t, schema)

	after := butterflyRows(t, conn)
	if len(after) != 1 || after[0].ID != id || after[0].URL != butterflyDriveURL {
		t.Fatalf("after the first boot: %+v, want one row, id %d, at %s", after, id, butterflyDriveURL)
	}
	if got := ownership(t, conn, wearer) + ownership(t, conn, owner); got != ownedBefore {
		t.Fatalf("ownership changed in the move:\n got %s\nwant %s", got, ownedBefore)
	}
	// Every other catalogue row v1.3.0 seeded is still there on its own id.
	for otherID, url := range others {
		if got := urlOf(t, conn, otherID); got != url {
			t.Errorf("row %d moved from %s to %q", otherID, url, got)
		}
	}
	// As the server reads it: the wearer's face is the Drive file, and both
	// players still own the picture.
	assertWearsAndOwns(t, d, wearer, id)
	assertWearsAndOwns(t, d, owner, 0)
	if !owns(t, d, owner, id) {
		t.Fatalf("%s lost Butterfly Flapping in the move", owner)
	}

	assertBootsChangeNothing(t, schema, conn)
}

// A rollback to go-server/v1.3.0 after the move re-runs the old INSERT, which
// no longer conflicts, and seeds a second row at the served path that players
// can buy and wear. The next boot of this build folds that duplicate into the
// original: one row, the original id, and nobody loses a purchase or a face.
func TestARollbackDuplicateOfButterflyFlappingFoldsIntoTheOriginalWithoutLosingOwnership(t *testing.T) {
	schema, conn := butterflySchema(t)
	bootNow(t, schema)
	original := butterflyRows(t, conn)[0].ID

	// The rollback's boot: v1.3.0's own V1.0.2, as that build would run it.
	runScript(t, conn, "v1.3.0 V1.0.2 (the rollback)", migrationAtV130(t, "V1.0.2__seed_animated_pictures.sql"))
	rows := butterflyRows(t, conn)
	if len(rows) != 2 || rows[0].ID != original || rows[1].URL != butterflyOldURL {
		t.Fatalf("the rollback should add a second row at %s after id %d, found %+v", butterflyOldURL, original, rows)
	}
	duplicate := rows[1].ID

	start := nowMs()
	ms := func(span time.Duration) int64 { return span.Milliseconds() }
	// Keeps the original and wears it, as before the rollback.
	addPlayer(t, conn, "kept")
	own(t, conn, "kept", original, start, start+ms(40*day), 1)
	wear(t, conn, "kept", original)
	// Bought only the duplicate during the rollback, and wears it.
	addPlayer(t, conn, "rolled")
	own(t, conn, "rolled", duplicate, start, start+ms(100*day), 1)
	wear(t, conn, "rolled", duplicate)
	// Holds both, each with time left: keeps the later term plus what was left
	// of the earlier one, and both purchase counts.
	addPlayer(t, conn, "both")
	own(t, conn, "both", original, start-ms(90*day), start+ms(10*day), 2)
	own(t, conn, "both", duplicate, start-ms(50*day), start+ms(50*day), 1)
	// Holds both, one already lapsed: nothing is left of it to add.
	addPlayer(t, conn, "lapsed")
	own(t, conn, "lapsed", original, start-ms(70*day), start+ms(30*day), 1)
	own(t, conn, "lapsed", duplicate, start-ms(105*day), start-ms(5*day), 1)
	// Holds both, one for ever: never running out wins.
	addPlayer(t, conn, "forever")
	own(t, conn, "forever", original, start-ms(1*day), start+ms(99*day), 1)
	own(t, conn, "forever", duplicate, start-ms(2*day), 0, 1)
	keptBefore := ownership(t, conn, "kept")

	d := bootNow(t, schema)
	booted := nowMs()

	after := butterflyRows(t, conn)
	if len(after) != 1 || after[0].ID != original || after[0].URL != butterflyDriveURL {
		t.Fatalf("after the forward boot: %+v, want one row, id %d, at %s", after, original, butterflyDriveURL)
	}
	if n := countRows(t, conn, `SELECT count(*) FROM user_profile_pictures WHERE profile_picture_id = $1`, duplicate); n != 0 {
		t.Fatalf("%d ownership row(s) still point at the deleted duplicate %d", n, duplicate)
	}
	if n := countRows(t, conn, `SELECT count(*) FROM users WHERE active_picture_id IS NULL`); n != 3 {
		t.Fatalf("%d players wear nothing, want 3 (only kept and rolled wore it)", n)
	}

	if got := ownership(t, conn, "kept"); got != keptBefore {
		t.Fatalf("an untouched owner changed:\n got %s\nwant %s", got, keptBefore)
	}
	assertWearsAndOwns(t, d, "kept", original)

	assertOwnershipRow(t, conn, "rolled", original, start, start+ms(100*day), 1)
	assertWearsAndOwns(t, d, "rolled", original)

	// The earlier term's remaining time is measured at the boot, so allow for
	// the seconds between writing the rows and booting.
	both := ownershipRow(t, conn, "both", original)
	want := start + ms(50*day) + ms(10*day)
	if both.ExpiresAt > want || both.ExpiresAt < want-(booted-start)-1000 ||
		both.AcquiredAt != start-ms(50*day) || both.Purchases != 3 {
		t.Fatalf("both: %+v, want expiry about %d (later term plus the earlier one's remaining time), acquired %d, 3 purchases",
			both, want, start-ms(50*day))
	}
	assertOwnershipRow(t, conn, "lapsed", original, start-ms(70*day), start+ms(30*day), 2)
	assertOwnershipRow(t, conn, "forever", original, start-ms(1*day), 0, 2)
	for _, player := range []string{"both", "lapsed", "forever"} {
		if !owns(t, d, player, original) {
			t.Fatalf("%s no longer owns Butterfly Flapping after the fold", player)
		}
	}

	assertBootsChangeNothing(t, schema, conn)
}

// The same pair the other way round — the older row still at the served path,
// a newer one already at Drive, as a build that changed only the seed's URL
// would leave it. The older row is kept and moved; the newer one's buyers and
// wearers come with it.
func TestADriveDuplicateOfButterflyFlappingFoldsIntoAnOlderRowStillAtTheServedPath(t *testing.T) {
	schema, conn := butterflySchema(t)
	buildAtV130(t, conn)
	original := butterflyRows(t, conn)[0].ID

	var newer int64
	if err := conn.QueryRow(context.Background(), `
		INSERT INTO profile_pictures (name, asset_url, asset_format, currency, type, cost, duration_days, is_active, sort_order, created_at, updated_at)
		SELECT name, $1, asset_format, currency, type, cost, duration_days, is_active, sort_order, created_at, updated_at
		  FROM profile_pictures WHERE id = $2
		RETURNING id`, butterflyDriveURL, original).Scan(&newer); err != nil {
		t.Fatal(err)
	}

	start := nowMs()
	addPlayer(t, conn, "older-buyer")
	own(t, conn, "older-buyer", original, start, start+(20*day).Milliseconds(), 1)
	wear(t, conn, "older-buyer", original)
	addPlayer(t, conn, "newer-buyer")
	own(t, conn, "newer-buyer", newer, start, start+(80*day).Milliseconds(), 1)
	wear(t, conn, "newer-buyer", newer)

	d := bootNow(t, schema)

	after := butterflyRows(t, conn)
	if len(after) != 1 || after[0].ID != original || after[0].URL != butterflyDriveURL {
		t.Fatalf("after the boot: %+v, want one row, id %d (the older), at %s", after, original, butterflyDriveURL)
	}
	assertOwnershipRow(t, conn, "older-buyer", original, start, start+(20*day).Milliseconds(), 1)
	assertOwnershipRow(t, conn, "newer-buyer", original, start, start+(80*day).Milliseconds(), 1)
	assertWearsAndOwns(t, d, "older-buyer", original)
	assertWearsAndOwns(t, d, "newer-buyer", original)

	assertBootsChangeNothing(t, schema, conn)
}

// ---------------------------------------------------------------- helpers

type catalogueRow struct {
	ID  int64
	URL string
}

type ownershipRecord struct {
	PictureID  int64
	AcquiredAt int64
	ExpiresAt  int64
	Purchases  int
}

// butterflySchema names a throwaway schema and returns an admin connection
// whose search_path leads with it. The schema is dropped on that connection
// when the test ends, after every pool the test booted has closed.
func butterflySchema(t *testing.T) (string, *pgx.Conn) {
	t.Helper()
	_ = dbtest.Open(t, "db") // skips when Postgres is unreachable
	ctx := context.Background()
	conn, err := pgx.Connect(ctx, testURL())
	if err != nil {
		t.Skipf("connect to %s: %v", db.Redact(testURL()), err)
	}
	schema := "test_db_butterfly_" + randomSuffix(t)
	ident := pgx.Identifier{schema}.Sanitize()
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		if _, err := conn.Exec(ctx, `DROP SCHEMA IF EXISTS `+ident+` CASCADE`); err != nil {
			t.Errorf("drop schema %s: %v", schema, err)
		}
		_ = conn.Close(ctx)
	})
	if _, err := conn.Exec(ctx, `CREATE SCHEMA `+ident); err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Exec(ctx, `SET search_path TO `+ident+`, public`); err != nil {
		t.Fatal(err)
	}
	return schema, conn
}

// buildAtV130 builds the schema exactly as go-server/v1.3.0 booted it, from
// that tag's own scripts, so the old row is the one production holds rather
// than a reconstruction of it.
func buildAtV130(t *testing.T, conn *pgx.Conn) {
	t.Helper()
	for _, file := range v130Migrations {
		runScript(t, conn, "v1.3.0 "+file, migrationAtV130(t, file))
	}
}

// migrationAtV130 reads one script out of the v1.3.0 tag. It skips without git
// or the tag (a shallow clone), and a skip proves nothing: run it in a full
// checkout.
func migrationAtV130(t *testing.T, file string) string {
	t.Helper()
	out, err := exec.Command("git", "show", v130Tag+":go-server/internal/db/migration/"+file).Output()
	if err != nil {
		t.Skipf("needs git and the go-server/v1.3.0 tag to rebuild production's schema: git show %s: %v", file, err)
	}
	return string(out)
}

// runScript runs one whole script, as the bootstrap does: no arguments, so pgx
// sends it on the simple protocol and the $$ bodies survive.
func runScript(t *testing.T, conn *pgx.Conn, what, sql string) {
	t.Helper()
	if _, err := conn.Exec(context.Background(), sql); err != nil {
		t.Fatalf("run %s: %v", what, err)
	}
}

// bootNow is one server start of this build on the schema: db.Open runs every
// embedded migration.
func bootNow(t *testing.T, schema string) *db.DB {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	d, err := db.Open(ctx, db.Options{URL: testURL(), Schema: schema, PoolMax: 2})
	if err != nil {
		t.Fatalf("boot %s: %v", schema, err)
	}
	t.Cleanup(d.Close)
	return d
}

// assertBootsChangeNothing boots twice more and requires the catalogue, every
// ownership row and every wearer to be byte for byte what they were — updated_at
// stamps included, which a guard that re-did its work would move.
func assertBootsChangeNothing(t *testing.T, schema string, conn *pgx.Conn) {
	t.Helper()
	settled := pictureState(t, conn)
	for boot := 1; boot <= 2; boot++ {
		bootNow(t, schema)
		if got := pictureState(t, conn); got != settled {
			t.Fatalf("boot %d after convergence changed the pictures:\n got %s\nwant %s", boot, got, settled)
		}
	}
}

// pictureState is everything the move could touch, as one comparable string.
func pictureState(t *testing.T, conn *pgx.Conn) string {
	t.Helper()
	var state string
	if err := conn.QueryRow(context.Background(), `
		SELECT concat_ws(E'\n--\n',
		  (SELECT string_agg(concat_ws('|', id, name, asset_url, asset_format, currency, type, cost,
		                               duration_days, is_active, sort_order, created_at, updated_at), E'\n' ORDER BY id)
		     FROM profile_pictures),
		  (SELECT string_agg(concat_ws('|', user_id, profile_picture_id, acquired_at, expires_at, purchases), E'\n'
		                     ORDER BY user_id, profile_picture_id)
		     FROM user_profile_pictures),
		  (SELECT string_agg(concat_ws('|', id, active_picture_id, updated_at), E'\n' ORDER BY id) FROM users))`).
		Scan(&state); err != nil {
		t.Fatal(err)
	}
	return state
}

// butterflyRows is every 'Butterfly Flapping' row, oldest first.
func butterflyRows(t *testing.T, conn *pgx.Conn) []catalogueRow {
	t.Helper()
	rows, err := conn.Query(context.Background(),
		`SELECT id, asset_url FROM profile_pictures WHERE name = 'Butterfly Flapping' ORDER BY id`)
	if err != nil {
		t.Fatal(err)
	}
	out, err := pgx.CollectRows(rows, pgx.RowToStructByPos[catalogueRow])
	if err != nil {
		t.Fatal(err)
	}
	return out
}

// catalogueExcept maps every other catalogue row's id to its URL.
func catalogueExcept(t *testing.T, conn *pgx.Conn, id int64) map[int64]string {
	t.Helper()
	rows, err := conn.Query(context.Background(), `SELECT id, asset_url FROM profile_pictures WHERE id <> $1`, id)
	if err != nil {
		t.Fatal(err)
	}
	list, err := pgx.CollectRows(rows, pgx.RowToStructByPos[catalogueRow])
	if err != nil {
		t.Fatal(err)
	}
	out := make(map[int64]string, len(list))
	for _, r := range list {
		out[r.ID] = r.URL
	}
	return out
}

func urlOf(t *testing.T, conn *pgx.Conn, id int64) string {
	t.Helper()
	var url string
	if err := conn.QueryRow(context.Background(), `SELECT COALESCE((SELECT asset_url FROM profile_pictures WHERE id = $1), '')`, id).Scan(&url); err != nil {
		t.Fatal(err)
	}
	return url
}

func countRows(t *testing.T, conn *pgx.Conn, sql string, args ...any) int64 {
	t.Helper()
	var n int64
	if err := conn.QueryRow(context.Background(), sql, args...).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

// addPlayer writes a bare account the way the columns require it — not through
// db.Users, which belongs to this build and not to the schema v1.3.0 built.
func addPlayer(t *testing.T, conn *pgx.Conn, id string) {
	t.Helper()
	stamp := nowMs()
	if _, err := conn.Exec(context.Background(), `
		INSERT INTO users (id, provider, provider_user_id, display_name, created_at, updated_at, last_login_at)
		VALUES ($1, 'guest', $1, $1, $2, $2, $2)`, id, stamp); err != nil {
		t.Fatal(err)
	}
}

func own(t *testing.T, conn *pgx.Conn, userID string, pictureID, acquiredAt, expiresAt int64, purchases int) {
	t.Helper()
	if _, err := conn.Exec(context.Background(), `
		INSERT INTO user_profile_pictures (user_id, profile_picture_id, acquired_at, expires_at, purchases)
		VALUES ($1, $2, $3, $4, $5)`, userID, pictureID, acquiredAt, expiresAt, purchases); err != nil {
		t.Fatal(err)
	}
}

func wear(t *testing.T, conn *pgx.Conn, userID string, pictureID int64) {
	t.Helper()
	if _, err := conn.Exec(context.Background(), `UPDATE users SET active_picture_id = $2 WHERE id = $1`, userID, pictureID); err != nil {
		t.Fatal(err)
	}
}

// ownership renders a player's ownership rows for comparison.
func ownership(t *testing.T, conn *pgx.Conn, userID string) string {
	t.Helper()
	rows, err := conn.Query(context.Background(), `
		SELECT profile_picture_id, acquired_at, expires_at, purchases
		  FROM user_profile_pictures WHERE user_id = $1 ORDER BY profile_picture_id`, userID)
	if err != nil {
		t.Fatal(err)
	}
	list, err := pgx.CollectRows(rows, pgx.RowToStructByPos[ownershipRecord])
	if err != nil {
		t.Fatal(err)
	}
	return fmt.Sprintf("%s:%+v;", userID, list)
}

// ownershipRow is a player's one ownership row, failing unless it is exactly
// one, on pictureID.
func ownershipRow(t *testing.T, conn *pgx.Conn, userID string, pictureID int64) ownershipRecord {
	t.Helper()
	rows, err := conn.Query(context.Background(), `
		SELECT profile_picture_id, acquired_at, expires_at, purchases
		  FROM user_profile_pictures WHERE user_id = $1 ORDER BY profile_picture_id`, userID)
	if err != nil {
		t.Fatal(err)
	}
	list, err := pgx.CollectRows(rows, pgx.RowToStructByPos[ownershipRecord])
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 1 || list[0].PictureID != pictureID {
		t.Fatalf("%s owns %+v, want exactly one row on picture %d", userID, list, pictureID)
	}
	return list[0]
}

func assertOwnershipRow(t *testing.T, conn *pgx.Conn, userID string, pictureID, acquiredAt, expiresAt int64, purchases int) {
	t.Helper()
	got := ownershipRow(t, conn, userID, pictureID)
	want := ownershipRecord{PictureID: pictureID, AcquiredAt: acquiredAt, ExpiresAt: expiresAt, Purchases: purchases}
	if got != want {
		t.Fatalf("%s's ownership row = %+v, want %+v", userID, got, want)
	}
}

// assertWearsAndOwns checks, through the server's own stores, that the player
// wears pictureID and draws it from Drive — or, for 0, wears nothing.
func assertWearsAndOwns(t *testing.T, d *db.DB, userID string, pictureID int64) {
	t.Helper()
	u, err := db.NewUsers(d, welcome, nil).FindByID(context.Background(), userID)
	if err != nil || u == nil {
		t.Fatalf("find %s: %v", userID, err)
	}
	if pictureID == 0 {
		if u.ActivePictureID != nil {
			t.Fatalf("%s wears picture %d, want none", userID, *u.ActivePictureID)
		}
		return
	}
	if u.ActivePictureID == nil || *u.ActivePictureID != pictureID {
		t.Fatalf("%s wears %v, want picture %d", userID, u.ActivePictureID, pictureID)
	}
	if u.AvatarURL == nil || *u.AvatarURL != butterflyDriveURL {
		t.Fatalf("%s's face resolves to %v, want %s", userID, u.AvatarURL, butterflyDriveURL)
	}
	if !owns(t, d, userID, pictureID) {
		t.Fatalf("%s wears picture %d without owning it", userID, pictureID)
	}
}

// owns is the picker's answer: may this player wear the picture right now.
func owns(t *testing.T, d *db.DB, userID string, pictureID int64) bool {
	t.Helper()
	users := db.NewUsers(d, welcome, nil)
	pic, active, err := db.NewPictures(d, users, nil).Find(context.Background(), userID, pictureID)
	if err != nil {
		t.Fatalf("find picture %d for %s: %v", pictureID, userID, err)
	}
	if !active || pic.URL != butterflyDriveURL {
		t.Fatalf("picture %d is active=%v at %s, want active at %s", pictureID, active, pic.URL, butterflyDriveURL)
	}
	return pic.Owned
}
