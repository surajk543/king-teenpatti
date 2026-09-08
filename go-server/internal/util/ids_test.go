package util

import (
	"regexp"
	"testing"
)

func TestRoomCodeUsesTheUnambiguousAlphabet(t *testing.T) {
	pattern := regexp.MustCompile(`^[` + RoomCodeAlphabet + `]{6}$`)
	for i := 0; i < 200; i++ {
		code := RoomCode(DefaultRoomCodeLength)
		if !pattern.MatchString(code) {
			t.Fatalf("code %q outside the alphabet", code)
		}
	}
}

func TestUUIDIsCanonicalV4(t *testing.T) {
	pattern := regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
	if id := UUID(); !pattern.MatchString(id) {
		t.Fatalf("uuid %q is not a canonical v4", id)
	}
}
