package auth

import (
	"net/http/httptest"
	"testing"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
)

// Pagination (owner, 27 Sep 2026: "All apis should be pagination and default
// page size is 20"): a page is 20 unless the request says otherwise, never
// more than MaxPageSize, and a cursor is only ever one this server wrote.

func TestAPageIsTwentyByDefaultAtMostAHundredAndAWholeNumber(t *testing.T) {
	for query, want := range map[string]int{
		"":           DefaultPageSize,
		"?limit=":    DefaultPageSize,
		"?limit=1":   1,
		"?limit=35":  35,
		"?limit=100": 100,
		"?limit=101": MaxPageSize,
		"?limit=9e9": -1,
		"?limit=0":   -1,
		"?limit=-3":  -1,
		"?limit=2.5": -1,
		"?limit=ten": -1,
	} {
		page, ok := ReadPage(httptest.NewRequest("GET", "/api/friends"+query, nil))
		if want < 0 {
			if ok {
				t.Errorf("%q read as %+v, want invalid_page", query, page)
			}
			continue
		}
		if !ok || page.Limit != want {
			t.Errorf("%q → %+v %v, want limit %d", query, page, ok, want)
		}
	}
	long := "?cursor="
	for range maxCursorLen + 1 {
		long += "a"
	}
	if _, ok := ReadPage(httptest.NewRequest("GET", "/api/friends"+long, nil)); ok {
		t.Error("a cursor longer than any this server writes was read")
	}
}

func TestCursorsReadBackAndOnlyTheirOwnKind(t *testing.T) {
	for _, n := range []int{0, 1, 20, 4096} {
		if got, ok := ReadOffsetCursor(OffsetCursor(n)); !ok || got != n {
			t.Errorf("offset %d read back as %d %v", n, got, ok)
		}
	}
	if got, ok := ReadOffsetCursor(""); !ok || got != 0 {
		t.Errorf("no cursor: %d %v, want the first page", got, ok)
	}
	k := db.Keyset{At: 1790518446149, ID: 42}
	if got, ok := readKeysetCursor(keysetCursor(k)); !ok || got == nil || *got != k {
		t.Errorf("keyset %+v read back as %+v %v", k, got, ok)
	}
	if got, ok := readKeysetCursor(""); !ok || got != nil {
		t.Errorf("no cursor: %+v %v, want the first page", got, ok)
	}
	for _, bad := range []string{"!!", "bm9wZQ", OffsetCursor(3), "azox"} {
		if _, ok := readKeysetCursor(bad); ok {
			t.Errorf("keyset cursor %q was read", bad)
		}
	}
	for _, bad := range []string{"!!", keysetCursor(k), "bzotMQ"} {
		if _, ok := ReadOffsetCursor(bad); ok {
			t.Errorf("offset cursor %q was read", bad)
		}
	}
}

func TestPageBoundsCutTheListAndSayWhereTheNextPageStarts(t *testing.T) {
	for _, c := range []struct {
		offset, limit, total, start, end int
		next                             bool
	}{
		{0, 20, 0, 0, 0, false},
		{0, 20, 7, 0, 7, false},
		{0, 20, 20, 0, 20, false},
		{0, 20, 25, 0, 20, true},
		{20, 20, 25, 20, 25, false},
		{40, 20, 25, 25, 25, false},
	} {
		start, end, next := PageBounds(c.offset, c.limit, c.total)
		if start != c.start || end != c.end || (next != nil) != c.next {
			t.Errorf("%+v → [%d, %d) next %v", c, start, end, next)
		}
		if next != nil {
			if n, _ := ReadOffsetCursor(*next); n != c.end {
				t.Errorf("%+v: the next page starts at %d", c, n)
			}
		}
	}
}
