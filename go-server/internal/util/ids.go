// Package util holds the two cross-cutting helpers every other package leans
// on: identifiers (util/ids.go ← server/src/util/ids.js) and the structured
// logger (util/logger.go ← server/src/util/logger.js).
//
// Nothing here knows about the game. Keep it that way.
package util

import (
	"crypto/rand"

	"github.com/google/uuid"
)

// RoomCodeAlphabet is the unambiguous alphabet room codes are drawn from:
// no 0/O/1/I, so a code can be read out loud or typed from a screenshot
// without confusion (server/src/util/ids.js).
const RoomCodeAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

// DefaultRoomCodeLength is how long every table code is: 8 characters (owner,
// 13 Sep 2026). Node's roomCode() defaulted to 6; a private table's code is the
// only key to it, so it was lengthened, and JoinByCode refuses any join whose
// code is not exactly this shape (ValidRoomCode).
const DefaultRoomCodeLength = 8

// UUID returns a fresh random (v4) UUID in canonical lower-case form — the
// id used for users, tables, hands, chat messages, turn tokens and any move
// a client did not name itself (Node: crypto.randomUUID()).
func UUID() string {
	return uuid.NewString()
}

// RoomCode returns a short, human-typable table code of `length` characters
// drawn uniformly-ish from RoomCodeAlphabet using crypto/rand (Node used
// `randomBytes(length)[i] % 32`; 32 letters divide 256 exactly so the
// modulus is unbiased — keep the alphabet at 32 characters).
//
// RoomManager.CreateTable regenerates a code until it is unique. Keep the
// alphabet at 32 characters — the unbiased modulus above depends on it; the
// length is DefaultRoomCodeLength.
func RoomCode(length int) string {
	if length <= 0 {
		length = DefaultRoomCodeLength
	}
	bytes := make([]byte, length)
	if _, err := rand.Read(bytes); err != nil {
		// crypto/rand only fails when the OS entropy source is broken; a
		// chips game must not run in that state.
		panic("util.RoomCode: crypto/rand failed: " + err.Error())
	}
	out := make([]byte, length)
	for i, b := range bytes {
		out[i] = RoomCodeAlphabet[int(b)%len(RoomCodeAlphabet)]
	}
	return string(out)
}

// ValidRoomCode reports whether code has the shape of a table code: exactly
// DefaultRoomCodeLength ASCII letters or digits, in either case. It checks the
// shape only — whether a table carries the code is RoomManager's question —
// and it takes the whole of A–Z and 0–9 rather than RoomCodeAlphabet alone, so
// a code misread with an O or a 1 in it is answered "no table with that code"
// rather than "not a code".
func ValidRoomCode(code string) bool {
	if len(code) != DefaultRoomCodeLength {
		return false
	}
	for i := 0; i < len(code); i++ {
		c := code[i]
		if !((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) {
			return false
		}
	}
	return true
}
