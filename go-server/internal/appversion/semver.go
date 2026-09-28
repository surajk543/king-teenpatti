// Package appversion is the app version gate (owner, 28 Sep 2026: "the
// backend controls the minimum supported app version … The backend must ALSO
// enforce the minimum version for important API/WebSocket access so an old
// client cannot bypass the Flutter UI").
//
// It holds the one semantic-version comparison the server has (Version,
// Parse), the rule that turns what a client declares about itself into one of
// four states (Evaluate: NORMAL, SOFT_UPDATE, FORCE_UPDATE, MAINTENANCE), the
// per-platform configuration that rule reads (Config — the app_versions rows,
// db.AppVersions), a short in-process cache in front of that read (Source), and
// the Gate the REST layer and the socket handshake ask (Gate.Admit).
//
// A client declares itself with two values in one format everywhere: a
// platform (android, ios — the app builds; bot, tool, web — this project's own
// tooling) and the app's version, MAJOR.MINOR.PATCH. Over REST they are the
// headers X-App-Platform and X-App-Version; over Socket.IO the handshake's
// auth object carries them beside the token, as appPlatform and appVersion.
//
// The package imports nothing of the server's: the auth and socket layers
// import it, and it reports what it decides through Hooks (metrics) and its
// logger, never by reaching back.
package appversion

import (
	"errors"
	"strconv"
	"strings"
)

// Version is a semantic version's core, MAJOR.MINOR.PATCH. The zero Version,
// 0.0.0, is what the configuration uses for "none": no minimum, no latest.
//
// Versions are compared field by field as numbers (Compare), never as text:
// "1.10.0" is newer than "1.9.0", which a string comparison gets backwards.
type Version struct {
	Major, Minor, Patch int
}

// ErrInvalid is Parse's refusal: the text is not MAJOR.MINOR.PATCH.
var ErrInvalid = errors.New("appversion: not a MAJOR.MINOR.PATCH version")

// maxComponentDigits bounds each number so it always fits an int (and a
// version string can never be used to make the server do unbounded work).
const maxComponentDigits = 9

// Parse reads MAJOR.MINOR.PATCH — three decimal numbers, each without a
// leading zero (0 itself excepted) and at most nine digits — optionally
// followed by a "+build" suffix, which is ignored ("1.5.0+13" is 1.5.0: a
// Flutter pubspec version carries its build number that way). Anything else is
// ErrInvalid: surrounding spaces, a "v" prefix, a pre-release ("1.5.0-beta"),
// two or four components, an empty build suffix. The database's CHECK on
// app_versions holds the stored versions to the same shape without the suffix.
func Parse(s string) (Version, error) {
	core := s
	if i := strings.IndexByte(s, '+'); i >= 0 {
		core = s[:i]
		if !validBuild(s[i+1:]) {
			return Version{}, ErrInvalid
		}
	}
	parts := strings.Split(core, ".")
	if len(parts) != 3 {
		return Version{}, ErrInvalid
	}
	var nums [3]int
	for i, p := range parts {
		n, ok := component(p)
		if !ok {
			return Version{}, ErrInvalid
		}
		nums[i] = n
	}
	return Version{Major: nums[0], Minor: nums[1], Patch: nums[2]}, nil
}

// MustParse is Parse for constants; it panics on a malformed version.
func MustParse(s string) Version {
	v, err := Parse(s)
	if err != nil {
		panic("appversion: MustParse(" + strconv.Quote(s) + "): " + err.Error())
	}
	return v
}

// component reads one number of the core: digits only, no leading zero.
func component(p string) (int, bool) {
	if p == "" || len(p) > maxComponentDigits {
		return 0, false
	}
	if len(p) > 1 && p[0] == '0' {
		return 0, false
	}
	n := 0
	for i := 0; i < len(p); i++ {
		c := p[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n*10 + int(c-'0')
	}
	return n, true
}

// validBuild is semver's build metadata: dot-separated identifiers of ASCII
// letters, digits and hyphens, none of them empty.
func validBuild(b string) bool {
	if b == "" || len(b) > 64 {
		return false
	}
	for _, id := range strings.Split(b, ".") {
		if id == "" {
			return false
		}
		for i := 0; i < len(id); i++ {
			c := id[i]
			if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '-') {
				return false
			}
		}
	}
	return true
}

// Compare is -1 when v is older than o, 0 when they are the same version and
// 1 when v is newer: major first, then minor, then patch, each as a number.
func (v Version) Compare(o Version) int {
	for _, d := range [3][2]int{{v.Major, o.Major}, {v.Minor, o.Minor}, {v.Patch, o.Patch}} {
		switch {
		case d[0] < d[1]:
			return -1
		case d[0] > d[1]:
			return 1
		}
	}
	return 0
}

// Less reports whether v is older than o.
func (v Version) Less(o Version) bool { return v.Compare(o) < 0 }

// IsZero reports whether v is 0.0.0 — "none" in the configuration.
func (v Version) IsZero() bool { return v == Version{} }

// String is MAJOR.MINOR.PATCH.
func (v Version) String() string {
	return strconv.Itoa(v.Major) + "." + strconv.Itoa(v.Minor) + "." + strconv.Itoa(v.Patch)
}
