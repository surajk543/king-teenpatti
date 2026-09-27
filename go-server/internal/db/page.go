package db

// Keyset is where a newest-first page of rows ended (owner, 27 Sep 2026: "All
// apis should be pagination and default page size is 20"): the last row's
// created_at and id. The next page is the rows strictly after it in
// (created_at DESC, id DESC) order — `(created_at, id) < (At, ID)` — so a row
// added at the top while the player scrolls neither repeats one they have
// seen nor hides one they have not. The REST layer writes it into an opaque
// cursor; nothing but that cursor carries it to a client.
type Keyset struct {
	At int64
	ID int64
}

// pageEnd is how many rows a page of limit asks for: one more than it shows,
// so the page knows whether another follows without a second query.
func pageEnd(limit int) int { return limit + 1 }
