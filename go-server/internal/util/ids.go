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

// DefaultRoomCodeLength is the length Node's roomCode() defaults to.
const DefaultRoomCodeLength = 6

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
// There is no collision check anywhere (CLAUDE.md §12.2) — RoomManager just
// trusts the code is unique. A porter may add a retry loop in
// RoomManager.CreateTable, but must not change the alphabet or length.
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
