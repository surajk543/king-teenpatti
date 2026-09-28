package appversion

import (
	"errors"
	"sort"
	"strings"
	"testing"
)

// The brief's own cases (§3, §20), and why a string comparison cannot be used:
// "1.10.0" < "1.9.0" as text.
func TestVersionsCompareAsNumbersNotAsText(t *testing.T) {
	cases := []struct {
		a, b string
		want int
	}{
		{"1.4.2", "1.5.0", -1},
		{"1.5.0", "1.5.0", 0},
		{"1.6.0", "1.5.0", 1},
		{"1.10.0", "1.9.0", 1},
		{"1.9.0", "1.10.0", -1},
		{"2.0.0", "1.99.99", 1},
		{"1.0.10", "1.0.9", 1},
		{"0.0.0", "0.0.1", -1},
		{"10.0.0", "9.9.9", 1},
		// A build suffix is ignored: 1.5.0+13 is 1.5.0.
		{"1.5.0+13", "1.5.0", 0},
		{"1.5.0+13", "1.5.0+14", 0},
		{"1.6.0+1", "1.5.0+99", 1},
	}
	for _, c := range cases {
		a, b := MustParse(c.a), MustParse(c.b)
		if got := a.Compare(b); got != c.want {
			t.Errorf("Compare(%s, %s) = %d, want %d", c.a, c.b, got, c.want)
		}
		if got := b.Compare(a); got != -c.want {
			t.Errorf("Compare(%s, %s) = %d, want %d", c.b, c.a, got, -c.want)
		}
		if a.Less(b) != (c.want < 0) {
			t.Errorf("Less(%s, %s) = %v", c.a, c.b, a.Less(b))
		}
	}
	if !("1.10.0" < "1.9.0") {
		t.Fatal("the text comparison this replaces was supposed to be wrong")
	}
}

func TestParseReadsMajorMinorPatchAndNothingElse(t *testing.T) {
	good := map[string]Version{
		"0.0.0":             {},
		"1.5.0":             {1, 5, 0},
		"1.10.0":            {1, 10, 0},
		"123456789.0.1":     {123456789, 0, 1},
		"1.5.0+13":          {1, 5, 0},
		"1.5.0+build.7-rc1": {1, 5, 0},
	}
	for in, want := range good {
		got, err := Parse(in)
		if err != nil || got != want {
			t.Errorf("Parse(%q) = %v, %v; want %v", in, got, err, want)
		}
	}
	bad := []string{
		"", " 1.5.0", "1.5.0 ", "v1.5.0", "1.5", "1", "1.5.0.0", "1..0", ".1.0", "1.0.",
		"1.5.0-beta", "1.5.0+", "1.5.0+a..b", "1.5.0+a_b", "01.5.0", "1.05.0", "1.5.00",
		"-1.5.0", "1.-5.0", "a.b.c", "1.5.x", "1234567890.0.0", "1,5,0", "１.5.0",
	}
	for _, in := range bad {
		if v, err := Parse(in); !errors.Is(err, ErrInvalid) {
			t.Errorf("Parse(%q) = %v, %v; want ErrInvalid", in, v, err)
		}
	}
}

func TestVersionsSortAndPrint(t *testing.T) {
	in := []string{"1.10.0", "1.9.0", "1.4.2", "1.5.0", "0.0.0", "2.0.0", "1.9.10"}
	vs := make([]Version, len(in))
	for i, s := range in {
		vs[i] = MustParse(s)
	}
	sort.Slice(vs, func(i, j int) bool { return vs[i].Less(vs[j]) })
	var out []string
	for _, v := range vs {
		out = append(out, v.String())
	}
	if got, want := strings.Join(out, " "), "0.0.0 1.4.2 1.5.0 1.9.0 1.9.10 1.10.0 2.0.0"; got != want {
		t.Errorf("sorted: %s, want %s", got, want)
	}
	if !(Version{}).IsZero() || MustParse("0.0.1").IsZero() {
		t.Error("IsZero is 0.0.0 alone")
	}
}

func TestMustParsePanicsOnAMalformedVersion(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Error("MustParse(\"1.5\") did not panic")
		}
	}()
	MustParse("1.5")
}
