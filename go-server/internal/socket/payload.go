package socket

import (
	"bytes"
	"encoding/json"
	"math"
	"strconv"
	"strings"
)

// Tolerant decoding of inbound payloads, reproducing what Node's handlers saw.
//
// Every guarded handler in socket/index.js received `payload ?? {}` and then
// DESTRUCTURED it: `({ action, amount, actionId })`. A non-object payload —
// null, absent, 42, "string", [], [1,2], true — destructures to all-undefined
// fields, so it behaves exactly like {} (that is what makes `room:quickJoin`
// with payload null a legitimate default-stake join, invalidMoves.test.js:328).
// A field's VALUE keeps JavaScript's loose typing: `{action: {}}` is refused as
// `Unknown action "[object Object]"`, `{text: 12345}` says "12345", and
// `{isPrivate: null}` opens a PUBLIC table because `= true` defaults apply
// only to undefined. The helpers below encode those coercions once so every
// handler reads like its Node counterpart.

// jsonKind classifies one JSON value the way a JavaScript handler would see it.
type jsonKind int

const (
	kindAbsent jsonKind = iota // key not present → JS undefined
	kindNull
	kindString
	kindNumber
	kindBool
	kindArray
	kindObject
)

// payload is one inbound event argument after `payload ?? {}`.
type payload struct {
	fields map[string]json.RawMessage
}

// decodePayload takes the event's arguments (sio hands over everything after
// the event name) and returns the destructurable object: the first argument
// when it is a JSON object, an empty payload otherwise.
func decodePayload(args []json.RawMessage) payload {
	if len(args) == 0 {
		return payload{}
	}
	raw := bytes.TrimSpace(args[0])
	if len(raw) == 0 || raw[0] != '{' {
		return payload{}
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fields); err != nil {
		return payload{}
	}
	return payload{fields: fields}
}

// field returns the raw JSON of one key and its kind (kindAbsent when the key
// is missing — JS undefined).
func (p payload) field(key string) (json.RawMessage, jsonKind) {
	raw, ok := p.fields[key]
	if !ok {
		return nil, kindAbsent
	}
	return raw, kindOf(raw)
}

// kindOf classifies a present JSON value by its first byte.
func kindOf(raw json.RawMessage) jsonKind {
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 {
		return kindNull
	}
	switch raw[0] {
	case '{':
		return kindObject
	case '[':
		return kindArray
	case '"':
		return kindString
	case 't', 'f':
		return kindBool
	case 'n':
		return kindNull
	default:
		return kindNumber
	}
}

// isNullish is JavaScript's `x == null`: the values `??` skips over.
func isNullish(kind jsonKind) bool { return kind == kindAbsent || kind == kindNull }

// jsonString decodes a JSON string; ok is false for any other kind.
func jsonString(raw json.RawMessage, kind jsonKind) (string, bool) {
	if kind != kindString {
		return "", false
	}
	var s string
	if err := json.Unmarshal(raw, &s); err != nil {
		return "", false
	}
	return s, true
}

// jsString is JavaScript's String(x) for a JSON value (template-literal
// interpolation uses the same conversion): undefined → "undefined", null →
// "null", numbers in Number#toString form, booleans "true"/"false", arrays
// joined with "," (null/undefined elements empty, nested arrays flattened),
// objects "[object Object]".
func jsString(raw json.RawMessage, kind jsonKind) string {
	switch kind {
	case kindAbsent:
		return "undefined"
	case kindNull:
		return "null"
	case kindString:
		s, _ := jsonString(raw, kind)
		return s
	case kindNumber:
		return jsNumberString(raw)
	case kindBool:
		return string(bytes.TrimSpace(raw))
	case kindArray:
		var items []json.RawMessage
		if err := json.Unmarshal(raw, &items); err != nil {
			return ""
		}
		parts := make([]string, len(items))
		for i, item := range items {
			k := kindOf(item)
			if k == kindNull {
				continue // Array#join renders null and undefined as ""
			}
			parts[i] = jsString(item, k)
		}
		return strings.Join(parts, ",")
	default:
		return "[object Object]"
	}
}

// jsTruthy is JavaScript truthiness for a JSON value: undefined, null, false,
// 0 and "" are false; everything else (including [] and {}) is true.
func jsTruthy(raw json.RawMessage, kind jsonKind) bool {
	switch kind {
	case kindAbsent, kindNull:
		return false
	case kindBool:
		return bytes.Equal(bytes.TrimSpace(raw), []byte("true"))
	case kindNumber:
		f, err := strconv.ParseFloat(string(bytes.TrimSpace(raw)), 64)
		if err != nil {
			// Only an overflow can fail on valid JSON, and ±Infinity is truthy.
			return true
		}
		return f != 0
	case kindString:
		s, _ := jsonString(raw, kind)
		return s != ""
	default:
		return true
	}
}

// jsNumberString renders a JSON number literal as Number.prototype.toString
// would: JSON.parse first (so 1e3 → "1000", 1.0 → "1", -0 → "0"), then the
// shortest round-trip digits in positional form for 1e-6 ≤ |x| < 1e21 and
// exponent form ("1e+21", "1.5e-7") outside that range.
func jsNumberString(raw json.RawMessage) string {
	text := string(bytes.TrimSpace(raw))
	f, err := strconv.ParseFloat(text, 64)
	if err != nil {
		if math.IsInf(f, 1) {
			return "Infinity"
		}
		if math.IsInf(f, -1) {
			return "-Infinity"
		}
		return text
	}
	return formatJSNumber(f)
}

// formatJSNumber is Number.prototype.toString(10) for finite values.
func formatJSNumber(f float64) string {
	switch {
	case math.IsNaN(f):
		return "NaN"
	case math.IsInf(f, 1):
		return "Infinity"
	case math.IsInf(f, -1):
		return "-Infinity"
	case f == 0:
		return "0" // String(-0) is "0"
	}
	abs := math.Abs(f)
	if abs >= 1e21 || abs < 1e-6 {
		s := strconv.FormatFloat(f, 'e', -1, 64) // "1e+21", "1.5e-07"
		mant, exp, _ := strings.Cut(s, "e")
		sign := exp[:1]
		digits := strings.TrimLeft(exp[1:], "0")
		if digits == "" {
			digits = "0"
		}
		return mant + "e" + sign + digits
	}
	return strconv.FormatFloat(f, 'f', -1, 64)
}

// maxSafeInteger is Number.MAX_SAFE_INTEGER (2^53 − 1).
const maxSafeInteger = 1<<53 - 1

// parseAmount applies game:action's amount rule (socket/index.js): absent or
// null → no amount (the table picks the default rung); a JSON number that is
// a safe integer → that figure; anything else — a string ("100", "1e3"), a
// boolean, an array, an object, 1.5, or a number beyond ±(2^53 − 1) → false.
// Node used `typeof parsed !== 'number' || !Number.isSafeInteger(parsed)`,
// so the JSON literals 1e3 and 1.0 are the numbers 1000 and 1 and pass.
func parseAmount(raw json.RawMessage, kind jsonKind) (*int64, bool) {
	switch kind {
	case kindAbsent, kindNull:
		return nil, true
	case kindNumber:
		f, err := strconv.ParseFloat(string(bytes.TrimSpace(raw)), 64)
		if err != nil || f != math.Trunc(f) || math.Abs(f) > maxSafeInteger {
			return nil, false
		}
		v := int64(f)
		return &v, true
	default:
		return nil, false
	}
}

// invalidBoot is the sentinel bootAmount handed to the RoomManager for a
// client value that is not a positive integer. Node passed the raw value
// through (`bootAmount ?? config.game.bootAmount`) and assertStakeAllowed
// refused it with invalid_stake "That stake is not valid" — AFTER the
// already_in_room check. The Go RoomManager reads 0 as "use the default", so
// 0, 200.5, "lots", true and {} all become −1 here, which its AssertStakeAllowed
// refuses with the same code and message in the same position.
const invalidBoot int64 = -1

// bootArg is `bootAmount ?? config.game.bootAmount` as the RoomManager needs
// it: def for absent/null; the figure for a positive integer (an integer
// beyond int64 becomes math.MaxInt64 — still integral, still refused by the
// stake list or the chips check exactly as Node refused 1e300); invalidBoot
// for everything else.
func bootArg(raw json.RawMessage, kind jsonKind, def int64) int64 {
	switch kind {
	case kindAbsent, kindNull:
		return def
	case kindNumber:
		f, err := strconv.ParseFloat(string(bytes.TrimSpace(raw)), 64)
		if err != nil || f != math.Trunc(f) || f <= 0 {
			return invalidBoot
		}
		if f >= math.MaxInt64 {
			return math.MaxInt64
		}
		return int64(f)
	default:
		return invalidBoot
	}
}

// stringArg is a field Node compared or matched as a string (`category ===
// 'blind'`, `typeof actionId === 'string'`): the string itself, "" for any
// other kind.
func stringArg(raw json.RawMessage, kind jsonKind) string {
	s, _ := jsonString(raw, kind)
	return s
}

// chatTextArg is the coercion of `text` before sanitising (DECISIONS.md §4):
// a string as is, a number as its decimal string (Node's String()),
// everything else — objects, arrays, booleans, null, absent — as empty.
func chatTextArg(raw json.RawMessage, kind jsonKind) string {
	switch kind {
	case kindString:
		s, _ := jsonString(raw, kind)
		return s
	case kindNumber:
		return jsNumberString(raw)
	default:
		return ""
	}
}

// utf16Len counts UTF-16 code units — JavaScript's String#length, which is
// what Node measured actionId against (1..64).
func utf16Len(s string) int {
	n := 0
	for _, r := range s {
		if r >= 0x10000 {
			n += 2
		} else {
			n++
		}
	}
	return n
}

// noSuchCategory is the lobby:list filter for a truthy non-string category:
// Node's `!category || table.category === category` matched nothing for 42
// or {} (truthy, never equal to a category string), so the list came back
// empty rather than unfiltered.
const noSuchCategory = "\x00"

// ---- one decoder per inbound event ----

func decodeLobbyList(args []json.RawMessage) LobbyListRequest {
	p := decodePayload(args)
	raw, kind := p.field("category")
	req := LobbyListRequest{}
	switch {
	case kind == kindString:
		req.Category = stringArg(raw, kind)
	case jsTruthy(raw, kind):
		req.Category = noSuchCategory
	}
	return req
}

func decodeQuickJoin(args []json.RawMessage) QuickJoinRequest {
	p := decodePayload(args)
	req := QuickJoinRequest{}
	if raw, kind := p.field("bootAmount"); !isNullish(kind) {
		boot := bootArg(raw, kind, 0)
		req.BootAmount = &boot
	}
	req.Category = stringArg(p.field("category"))
	return req
}

func decodeCreate(args []json.RawMessage) CreateRequest {
	p := decodePayload(args)
	req := CreateRequest{}
	if raw, kind := p.field("bootAmount"); !isNullish(kind) {
		boot := bootArg(raw, kind, 0)
		req.BootAmount = &boot
	}
	// `isPrivate = true` is a destructuring default: it applies to undefined
	// only. null, false, 0 and "" open a public table; any other value
	// (true, 1, "yes", {}) is truthy and private, as Node stored it raw and
	// every reader tested truthiness.
	if raw, kind := p.field("isPrivate"); kind != kindAbsent {
		private := jsTruthy(raw, kind)
		req.IsPrivate = &private
	}
	req.Category = stringArg(p.field("category"))
	return req
}

func decodeJoinCode(args []json.RawMessage) JoinCodeRequest {
	p := decodePayload(args)
	raw, kind := p.field("code")
	if isNullish(kind) {
		return JoinCodeRequest{} // String(code ?? '')
	}
	return JoinCodeRequest{Code: jsString(raw, kind)}
}

func decodeAction(args []json.RawMessage) ActionRequest {
	p := decodePayload(args)
	req := ActionRequest{}
	raw, kind := p.field("action")
	req.Action = jsString(raw, kind) // `Unknown action "${action}"` interpolates String(action)
	if raw, kind := p.field("amount"); kind != kindAbsent {
		req.Amount = raw
	}
	req.ActionID = stringArg(p.field("actionId"))
	return req
}

func decodeSideshowRespond(args []json.RawMessage) SideshowRespondRequest {
	p := decodePayload(args)
	raw, kind := p.field("accept")
	if kind == kindAbsent {
		return SideshowRespondRequest{}
	}
	return SideshowRespondRequest{Accept: raw}
}

func decodeChat(args []json.RawMessage) ChatRequest {
	p := decodePayload(args)
	return ChatRequest{Text: chatTextArg(p.field("text"))}
}

// acceptsSideshow is `accept === true`: only the JSON literal true accepts;
// 1, "true", {} and everything else decline.
func acceptsSideshow(raw json.RawMessage) bool {
	return bytes.Equal(bytes.TrimSpace(raw), []byte("true"))
}
