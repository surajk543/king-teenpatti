package db

import "context"

// Assets says which asset URLs the catalogue stores (owner, 1 Oct 2026): the
// check POST /api/assets/sign makes before it signs anything, so a phone can
// have a signed URL for a file some catalogue row names — and for nothing
// else in the bucket.
type Assets struct {
	db *DB
}

// NewAssets is the store over d.
func NewAssets(d *DB) *Assets { return &Assets{db: d} }

// Stored is the subset of urls that some catalogue row names: a profile
// picture's asset_url, a table picture's day or night file, an emoji's, a
// badge's or a level's asset_url. Retired and unlisted rows count — a player
// may still wear a retired picture or hold an unlisted badge, and everybody at
// their table has to draw it.
func (a *Assets) Stored(ctx context.Context, urls []string) (map[string]bool, error) {
	out := map[string]bool{}
	if len(urls) == 0 {
		return out, nil
	}
	rows, err := a.db.Pool.Query(ctx,
		`SELECT u FROM unnest($1::text[]) AS u
		  WHERE EXISTS (SELECT 1 FROM profile_pictures p WHERE p.asset_url = u)
		     OR EXISTS (SELECT 1 FROM table_pictures t WHERE t.day_asset_url = u OR t.night_asset_url = u)
		     OR EXISTS (SELECT 1 FROM emojis e WHERE e.asset_url = u)
		     OR EXISTS (SELECT 1 FROM badges b WHERE b.asset_url = u)
		     OR EXISTS (SELECT 1 FROM player_levels l WHERE l.asset_url = u)`, urls)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var u string
		if err := rows.Scan(&u); err != nil {
			return nil, err
		}
		out[u] = true
	}
	return out, rows.Err()
}
