package auth

import (
	"encoding/base64"
	"net/http"
	"strconv"
	"strings"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
)

// Pagination (owner, 27 Sep 2026: "All apis should be pagination and default
// page size is 20" — "make sure that reported user should be fetched using
// pagination, and same with friend list, as user scroll, then it will fetch
// more"). Every route that lists what grows with a player — their friends,
// their friend requests, their reports, and the live tables — answers one
// page at a time:
//
//	?limit=N     the page's size: 20 when absent, at most MaxPageSize (a larger
//	             one is read as MaxPageSize), at least 1
//	?cursor=C    where the page starts: the previous page's nextCursor, opaque
//
// and says in its body how many there are in all (total) and where the next
// page starts (nextCursor, null on the last). A limit that is not a whole
// number of at least 1, or a cursor this route did not write, is 400
// invalid_page. The catalogues — pictures, emojis, table pictures, the
// levels, the table catalogue — are fixed sets the app needs whole, and stay
// one answer.
const (
	// DefaultPageSize is a page's size when the request names none.
	DefaultPageSize = 20
	// MaxPageSize is the largest page a request may ask for.
	MaxPageSize = 100
	// maxCursorLen bounds a cursor before it is decoded.
	maxCursorLen = 256
)

// The page refusal.
const (
	CodeInvalidPage = "invalid_page"
	MsgInvalidPage  = "That page does not exist."
)

// PageRequest is a list route's ?limit and ?cursor, read.
type PageRequest struct {
	Limit  int
	Cursor string
}

// ReadPage reads a request's page. false for a limit that is not a whole
// number of at least 1, or a cursor longer than any this server writes.
func ReadPage(r *http.Request) (PageRequest, bool) {
	q := r.URL.Query()
	page := PageRequest{Limit: DefaultPageSize, Cursor: q.Get("cursor")}
	if raw := strings.TrimSpace(q.Get("limit")); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil || n < 1 {
			return PageRequest{}, false
		}
		page.Limit = min(n, MaxPageSize)
	}
	if len(page.Cursor) > maxCursorLen {
		return PageRequest{}, false
	}
	return page, true
}

// RefusePage writes 400 invalid_page.
func RefusePage(w http.ResponseWriter) {
	WriteJSON(w, http.StatusBadRequest, ErrorResponse{Error: CodeInvalidPage, Message: MsgInvalidPage})
}

// OffsetCursor is the cursor of a page that starts [offset] rows into a list
// the server sorts itself (the friends, by presence; the live tables).
func OffsetCursor(offset int) string {
	return base64.RawURLEncoding.EncodeToString([]byte("o:" + strconv.Itoa(offset)))
}

// ReadOffsetCursor reads an OffsetCursor; "" is the first page (0).
func ReadOffsetCursor(cursor string) (int, bool) {
	if cursor == "" {
		return 0, true
	}
	raw, err := base64.RawURLEncoding.DecodeString(cursor)
	if err != nil {
		return 0, false
	}
	rest, ok := strings.CutPrefix(string(raw), "o:")
	if !ok {
		return 0, false
	}
	n, err := strconv.Atoi(rest)
	if err != nil || n < 0 {
		return 0, false
	}
	return n, true
}

// keysetCursor is the cursor of a newest-first page that starts after k.
func keysetCursor(k db.Keyset) string {
	return base64.RawURLEncoding.EncodeToString(
		[]byte("k:" + strconv.FormatInt(k.At, 10) + ":" + strconv.FormatInt(k.ID, 10)))
}

// readKeysetCursor reads a keysetCursor; "" is the first page (nil).
func readKeysetCursor(cursor string) (*db.Keyset, bool) {
	if cursor == "" {
		return nil, true
	}
	raw, err := base64.RawURLEncoding.DecodeString(cursor)
	if err != nil {
		return nil, false
	}
	rest, ok := strings.CutPrefix(string(raw), "k:")
	if !ok {
		return nil, false
	}
	at, id, ok := strings.Cut(rest, ":")
	if !ok {
		return nil, false
	}
	k := db.Keyset{}
	if k.At, err = strconv.ParseInt(at, 10, 64); err != nil {
		return nil, false
	}
	if k.ID, err = strconv.ParseInt(id, 10, 64); err != nil {
		return nil, false
	}
	return &k, true
}

// nextKeyset is a page's nextCursor: null on the last page.
func nextKeyset(next *db.Keyset) *string {
	if next == nil {
		return nil
	}
	c := keysetCursor(*next)
	return &c
}

// PageBounds is [start, end) of a page of limit starting at offset in a list
// of total, and the next page's cursor (nil on the last).
func PageBounds(offset, limit, total int) (start, end int, next *string) {
	start = min(offset, total)
	end = min(start+limit, total)
	if end < total {
		c := OffsetCursor(end)
		next = &c
	}
	return start, end, next
}
