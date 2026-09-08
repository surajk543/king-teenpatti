package auth

import (
	"encoding/json"
	"strconv"
	"unicode"
	"unicode/utf16"
)

// This file holds the JavaScript string semantics the login path depends on
// (providers.js sanitizeName / verifyGuest and the body coercions described
// in DECISIONS.md §4): UTF-16 length, JS `trim()`, `\p{C}` stripping and
// `String(x)` for non-string JSON values.

// jsonKind classifies a raw JSON value for the coercion rules.
type jsonKind int

const (
	jsonAbsent jsonKind = iota // key missing or JSON null
	jsonString
	jsonNumber
	jsonOther // object, array, boolean
)

// coerceText is DECISIONS.md §4's reading of Node's `String(x)`: strings as
// they are, numbers as their decimal text (1e3 → "1000", as JS prints it),
// null/absent/objects/arrays/booleans → "". The kind lets a caller apply a
// stricter rule (guest deviceId must be a real string).
func coerceText(raw json.RawMessage) (string, jsonKind) {
	if len(raw) == 0 || string(raw) == "null" {
		return "", jsonAbsent
	}
	switch raw[0] {
	case '"':
		var s string
		if err := json.Unmarshal(raw, &s); err != nil {
			return "", jsonOther
		}
		return s, jsonString
	case '{', '[', 't', 'f':
		return "", jsonOther
	}
	f, err := strconv.ParseFloat(string(raw), 64)
	if err != nil {
		return "", jsonOther
	}
	return strconv.FormatFloat(f, 'f', -1, 64), jsonNumber
}

// isJSWhitespace is the set JavaScript's trim() and \s remove: WhiteSpace
// (TAB VT FF SP NBSP ZWNBSP and every Zs) plus the LineTerminators (LF CR LS
// PS). Go's unicode.IsSpace differs at U+0085 (JS keeps it) and U+FEFF (JS
// strips it).
func isJSWhitespace(r rune) bool {
	switch r {
	case '\t', '\n', '\v', '\f', '\r', ' ', 0x00A0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
		return true
	}
	return r >= 0x2000 && r <= 0x200A
}

// jsTrim is String.prototype.trim.
func jsTrim(s string) string {
	runes := []rune(s)
	start, end := 0, len(runes)
	for start < end && isJSWhitespace(runes[start]) {
		start++
	}
	for end > start && isJSWhitespace(runes[end-1]) {
		end--
	}
	return string(runes[start:end])
}

// isCategoryC is JS `/\p{C}/u`: Cc, Cf, Co, Cs and — because V8 classifies
// unassigned code points as Cn — every rune Go's tables place in no category
// at all (DECISIONS.md §4).
func isCategoryC(r rune) bool {
	if unicode.Is(unicode.C, r) {
		return true
	}
	return !unicode.In(r, unicode.L, unicode.M, unicode.N, unicode.P, unicode.S, unicode.Z)
}

// utf16Len is JavaScript's .length: UTF-16 code units, so an emoji counts 2.
func utf16Len(s string) int {
	return len(utf16.Encode([]rune(s)))
}

// utf16Slice is `s.slice(0, n)` in code units, except that a surrogate pair
// straddling the cut is dropped whole rather than leaving a lone high
// surrogate behind (DECISIONS.md §4).
func utf16Slice(s string, n int) string {
	units := utf16.Encode([]rune(s))
	if len(units) <= n {
		return s
	}
	cut := n
	if cut > 0 && utf16.IsSurrogate(rune(units[cut-1])) && units[cut-1] < 0xDC00 {
		cut-- // a high surrogate would be left without its low half
	}
	return string(utf16.Decode(units[:cut]))
}
