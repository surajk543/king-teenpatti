package db_test

import (
	"encoding/csv"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
)

// seededAssets is where the seed's catalogue art lives (owner, 1 Oct 2026):
// the R2 bucket every file moved to from Google Drive, path-style on the
// account's S3 endpoint. A row stores this followed by the file's key.
const seededAssets = "https://a91cb23b3b93a35dd9ea50db7b855e18.r2.cloudflarestorage.com/king-teenpatti/"

// driveToR2 is tools/r2/drive-to-r2.tsv, the record of the move: each Drive
// URL — or path this server served — the seed used to name, and the key its
// file was copied to.
func driveToR2(t *testing.T) map[string]string {
	t.Helper()
	f, err := os.Open(filepath.Join("..", "..", "..", "tools", "r2", "drive-to-r2.tsv"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	r := csv.NewReader(f)
	r.Comma = '\t'
	rows, err := r.ReadAll()
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]string{}
	for _, row := range rows[1:] {
		out[row[2]] = row[3]
	}
	return out
}

// assetColumns is every column that names catalogue art.
var assetColumns = []struct{ table, column string }{
	{"profile_pictures", "asset_url"},
	{"table_pictures", "day_asset_url"},
	{"table_pictures", "night_asset_url"},
	{"cards_background", "asset_url"},
	{"emojis", "asset_url"},
	{"badges", "asset_url"},
	{"player_levels", "asset_url"},
}

// ownersCards are the keys of the card backs the seed names (owner, 3 Oct
// 2026), as a location writes them (each space %20). The owner uploaded them
// straight into the bucket's cards/ folder — they were never on Google Drive,
// so the move's record (tools/r2/drive-to-r2.tsv) names none of them, and is
// not a record of them. (Royal Fox, cards/Royal%20Fox.jpg, is the app's
// bundled default and no row.)
var ownersCards = map[string]bool{
	"cards/Brutal%20Demon.jpg":           true,
	"cards/Demon%20Hell.jpg":             true,
	"cards/Dragon%20Hunter.jpg":          true,
	"cards/Royal%20Lion.jpg":             true,
	"cards/Royal%20Majestic%20Fox.jpg":   true,
	"cards/Royal%20Owl%20with%20fox.jpg": true,
	"cards/Royal%20Tiger.jpg":            true,
	"cards/Royal%20White%20Tiger.jpg":    true,
	"cards/Flower%201.jpg":               true,
	"cards/Flower%202.jpg":               true,
	"cards/Flower%203.jpg":               true,
	"cards/Flower%204.jpg":               true,
	"cards/Flower%205.jpg":               true,
}

// assetURLs is every URL those columns hold, column by column.
func assetURLs(t *testing.T, f *fixture) map[string][]string {
	t.Helper()
	out := map[string][]string{}
	for _, c := range assetColumns {
		rows, err := f.d.Pool.Query(f.ctx, `SELECT `+c.column+` FROM `+c.table+` WHERE `+c.column+` IS NOT NULL ORDER BY 1`)
		if err != nil {
			t.Fatal(err)
		}
		for rows.Next() {
			var u string
			if err := rows.Scan(&u); err != nil {
				t.Fatal(err)
			}
			out[c.table+"."+c.column] = append(out[c.table+"."+c.column], u)
		}
		rows.Close()
	}
	return out
}

// A fresh database names no Google Drive file and no file of this server's:
// every piece of the catalogue's art is a location in the R2 bucket, a key
// tools/r2/migrate_drive_assets.py uploaded (the six levels this server used
// to serve from public/levels/ included) — or, for a card back (3 Oct 2026),
// one of the owner's own uploads to the bucket's cards/ folder, which the
// move never touched.
func TestEveryCatalogueFileIsInTheR2Bucket(t *testing.T) {
	f := newFixture(t)
	uploaded := map[string]bool{}
	for _, key := range driveToR2(t) {
		uploaded[key] = true
	}
	if len(uploaded) != 130 {
		t.Fatalf("the move's record names %d files, want 130", len(uploaded))
	}
	inBucket, cards := map[string]bool{}, map[string]bool{}
	for column, urls := range assetURLs(t, f) {
		for _, u := range urls {
			switch {
			case column == "cards_background.asset_url":
				// The owner's own uploads: a location in the bucket, never one
				// the move made.
				key := strings.TrimPrefix(u, seededAssets)
				if !strings.HasPrefix(u, seededAssets) || !ownersCards[key] || uploaded[key] {
					t.Errorf("%s names %s, not one of the owner's card backs in the bucket", column, u)
				}
				cards[key] = true
			case strings.HasPrefix(u, seededAssets):
				key := strings.TrimPrefix(u, seededAssets)
				if !uploaded[key] {
					t.Errorf("%s names %s, which the move never uploaded", column, key)
				}
				inBucket[key] = true
			default:
				t.Errorf("%s names %s, not a location in the bucket", column, u)
			}
		}
	}
	if len(inBucket) != len(uploaded) {
		t.Errorf("the seed names %d of the %d files the move uploaded", len(inBucket), len(uploaded))
	}
	if len(cards) != len(ownersCards) {
		t.Errorf("the seed names %d of the owner's %d card backs", len(cards), len(ownersCards))
	}
}

// A database seeded while the art was on Google Drive — production's — is
// moved onto the R2 locations by its next boot: every row that still names a
// Drive file the move copied now names that file's location, no row is added
// (the seed's INSERTs find the moved rows), the ids are the ids they were, an
// owner's own URL is left exactly as it is, and a second boot changes
// nothing.
func TestABootMovesADriveEraCatalogueOntoItsR2Locations(t *testing.T) {
	f := newFixture(t)
	fresh := assetURLs(t, f)
	tables := []string{"profile_pictures", "table_pictures", "cards_background", "emojis", "badges", "player_levels"}
	counts := func() map[string]int64 {
		out := map[string]int64{}
		for _, table := range tables {
			out[table] = f.count(`SELECT count(*) FROM ` + table)
		}
		return out
	}
	names := func(table string) string {
		var s string
		if err := f.d.Pool.QueryRow(f.ctx, `SELECT string_agg(id::text || ':' || name, ',' ORDER BY id) FROM `+table).Scan(&s); err != nil {
			t.Fatal(err)
		}
		return s
	}
	beforeCounts := counts()
	beforeNames := map[string]string{}
	for _, table := range []string{"profile_pictures", "table_pictures", "emojis"} {
		beforeNames[table] = names(table)
	}

	// Back to the Drive era: every location the move made, the Drive URL it
	// was. And one picture the owner added by hand on Drive, which no move
	// names.
	drive := driveToR2(t)
	for driveURL, key := range drive {
		for _, c := range assetColumns {
			if _, err := f.d.Pool.Exec(f.ctx, `UPDATE `+c.table+` SET `+c.column+` = $1 WHERE `+c.column+` = $2`,
				driveURL, seededAssets+key); err != nil {
				t.Fatal(err)
			}
		}
	}
	const ownersOwn = "https://drive.google.com/uc?export=download&id=OWNERS-OWN-PICTURE"
	if _, err := f.d.Pool.Exec(f.ctx, `INSERT INTO profile_pictures (name, asset_url, asset_format, currency, type, cost, created_at, updated_at)
	     VALUES ('Owner Pick', $1, 'LOTTIE', 'HAMMER', 'PREMIUM', 3, 0, 0)`, ownersOwn); err != nil {
		t.Fatal(err)
	}
	for column, urls := range assetURLs(t, f) {
		if column == "cards_background.asset_url" {
			// The owner's own uploads to R2 (3 Oct 2026), never on Drive: no
			// move made them, so none is undone, and the boots below leave
			// them exactly as they are.
			continue
		}
		for _, u := range urls {
			if strings.HasPrefix(u, seededAssets) {
				t.Fatalf("the Drive-era database still names %s in %s", u, column)
			}
		}
	}

	for boot := 1; boot <= 2; boot++ {
		d, err := db.Open(f.ctx, db.Options{URL: testURL(), Schema: f.d.Schema, PoolMax: 2})
		if err != nil {
			t.Fatalf("boot %d: %v", boot, err)
		}
		d.Close()
		after := assetURLs(t, f)
		for column, want := range fresh {
			got := after[column]
			if column == "profile_pictures.asset_url" {
				got = without(got, ownersOwn)
			}
			if strings.Join(got, "\n") != strings.Join(want, "\n") {
				t.Errorf("boot %d: %s holds\n%s\nwant\n%s", boot, column, strings.Join(got, "\n"), strings.Join(want, "\n"))
			}
		}
		var own string
		if err := f.d.Pool.QueryRow(f.ctx, `SELECT asset_url FROM profile_pictures WHERE name = 'Owner Pick'`).Scan(&own); err != nil || own != ownersOwn {
			t.Errorf("boot %d: the owner's own picture is at %q (%v), want it untouched", boot, own, err)
		}
		got := counts()
		for _, table := range tables {
			want := beforeCounts[table]
			if table == "profile_pictures" {
				want++ // the owner's hand-added picture
			}
			if got[table] != want {
				t.Errorf("boot %d: %s holds %d rows, want %d — a row added twice?", boot, table, got[table], want)
			}
		}
		for table, want := range beforeNames {
			if got := names(table); !strings.HasPrefix(got, want) {
				t.Errorf("boot %d renumbered %s:\n%s\nwant\n%s", boot, table, got, want)
			}
		}
	}
}

// Stored answers which URLs some catalogue row names — any row, retired or
// unlisted ones too — and nothing else: not a key the catalogue does not use,
// not another host's URL.
func TestStoredNamesWhatTheCatalogueStoresAndNothingElse(t *testing.T) {
	f := newFixture(t)
	store := db.NewAssets(f.d)
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE emojis SET is_active = FALSE, is_listed = FALSE WHERE name = 'Knife'`); err != nil {
		t.Fatal(err)
	}
	// A retired card back still counts: whoever chose it keeps it on their
	// cards, and everybody at their table draws it.
	if _, err := f.d.Pool.Exec(f.ctx, `UPDATE cards_background SET is_active = FALSE, is_listed = FALSE WHERE name = 'Demon Hell'`); err != nil {
		t.Fatal(err)
	}
	asked := []string{
		seededAssets + "profile_pictures/bear.png",
		seededAssets + "table_pictures/thank-you-night.json",
		seededAssets + "cards/Brutal%20Demon.jpg",
		seededAssets + "cards/Demon%20Hell.jpg",
		seededAssets + "cards/Royal%20Fox.jpg",  // the bundled default: in the bucket, named by no row
		seededAssets + "cards/Brutal Demon.jpg", // not the location the row stores
		seededAssets + "emojis/knife.json",
		seededAssets + "badges/royal-ace.json",
		seededAssets + "levels/02-rookie.json",
		seededAssets + "emojis/3.13.0.txt",
		seededAssets + "profile_pictures/nobody.png",
		"https://lh3.googleusercontent.com/a/photo",
		"",
	}
	stored, err := store.Stored(f.ctx, asked)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for u := range stored {
		got = append(got, strings.TrimPrefix(u, seededAssets))
	}
	sort.Strings(got)
	want := []string{"badges/royal-ace.json", "cards/Brutal%20Demon.jpg", "cards/Demon%20Hell.jpg", "emojis/knife.json", "levels/02-rookie.json",
		"profile_pictures/bear.png", "table_pictures/thank-you-night.json"}
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("Stored = %v, want %v", got, want)
	}
	if none, err := store.Stored(f.ctx, nil); err != nil || len(none) != 0 {
		t.Fatalf("Stored(nil) = %v, %v", none, err)
	}
}

func without(urls []string, drop string) []string {
	out := urls[:0:0]
	for _, u := range urls {
		if u != drop {
			out = append(out, u)
		}
	}
	return out
}
