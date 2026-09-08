package live

import (
	"strings"
	"testing"
)

func TestHandIDOf(t *testing.T) {
	cases := map[string]string{
		`{"roomId":"r","hand":{"id":"h-1","pot":5},"seats":[]}`:                  "h-1",
		`{"roomId":"r","hand":null,"seats":[]}`:                                  "",
		`{"roomId":"r","seats":[{"hand":{"id":"nested"}}],"hand":{"id":"late"}}`: "late",
		`{"seats":[{"hand":{"id":"nested"}}],"meta":{"hand":{"id":"deep"}}}`:     "",
		`{"hand":{"contributions":[{"id":"c"}],"id":"after-array"}}`:             "after-array",
		`{"hand":"not-an-object"}`:                                               "",
		`[1,2,3]`:                                                                "",
		`not json`:                                                               "",
		``:                                                                       "",
		`{"pad":"` + strings.Repeat("x", 30000) + `","hand":{"id":"at-the-end"}}`: "at-the-end",
	}
	for doc, want := range cases {
		if got := HandIDOf([]byte(doc)); got != want {
			name := doc
			if len(name) > 60 {
				name = name[:60] + "…"
			}
			t.Errorf("HandIDOf(%s) = %q, want %q", name, got, want)
		}
	}
	if got := HandIDOf(bigSnapshot("bench-hand", 20*1024)); got != "bench-hand" {
		t.Errorf("bigSnapshot hand id = %q", got)
	}
}
