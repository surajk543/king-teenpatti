package util

import (
	"regexp"
	"testing"
)

func TestRoomCodeUsesTheUnambiguousAlphabet(t *testing.T) {
	pattern := regexp.MustCompile(`^[` + RoomCodeAlphabet + `]{8}$`)
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

func TestValidRoomCodeWantsEightLettersOrDigits(t *testing.T) {
	for _, ok := range []string{"ABCD2345", "abcd2345", "ZZZZ0000", RoomCode(DefaultRoomCodeLength)} {
		if !ValidRoomCode(ok) {
			t.Errorf("%q refused", ok)
		}
	}
	for _, bad := range []string{"", "NOPE00", "ABC2345", "ABCD23456", "ABCD-234", "ABCD 234", "ÄBCD234"} {
		if ValidRoomCode(bad) {
			t.Errorf("%q accepted", bad)
		}
	}
}
