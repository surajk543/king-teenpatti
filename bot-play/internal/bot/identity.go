// Package bot is one bot and the fleet of them: a bot is a normal game
// client — it signs in as a guest device, connects with the token, finds a
// table on the menu the server publishes, plays the moves the server offers
// and leaves — and the Manager runs many of them side by side, each on its
// own goroutine, its own connection and its own random stream.
//
// The game server stays the authority on everything: a bot decides only WHAT
// to do (strategy) and WHEN (timing), and every move goes through the same
// events and the same validation as a player's.
package bot

import (
	"fmt"
	"hash/fnv"
)

// Identity is who a bot is: a stable guest device and a display name. The
// device id is what the server's login keys the account on, and its prefix
// (botplay-) is the namespace the server marks is_bot from — the bot sends
// nothing else to say what it is, and nothing on the wire tells a player.
type Identity struct {
	Index    int    // 0-based position in the fleet
	Number   int    // StartIndex + Index: the number in the device id
	DeviceID string // "botplay-000017"
	Name     string // "Kabir_07" — used when the account is first created
}

// NewIdentity is bot number n of prefix. generation > 0 appends "-g<gen>"
// (a fresh account, used only by the simulation's replenishment).
func NewIdentity(prefix string, index, number, generation int) Identity {
	id := fmt.Sprintf("%s%06d", prefix, number)
	if generation > 0 {
		id = fmt.Sprintf("%s-g%d", id, generation)
	}
	return Identity{Index: index, Number: number, DeviceID: id, Name: nameFor(number)}
}

// Seed is a stable 64-bit value for the identity: a bot's PERSONALITY is
// drawn from it, so the same account plays the same way on every run (a
// person is the same person tomorrow), whatever the fleet's behaviour seed.
func (id Identity) Seed() uint64 {
	h := fnv.New64a()
	_, _ = h.Write([]byte(id.DeviceID))
	return h.Sum64()
}

// Names that read like a real lobby rather than Bot001, carried over from
// the Node fleet (identities.js): a first name and, for some, a suffix.
var firstNames = []string{
	"Aarav", "Vivaan", "Aditya", "Vihaan", "Arjun", "Sai", "Reyansh", "Krishna",
	"Ishaan", "Rudra", "Kabir", "Ansh", "Dhruv", "Yash", "Rohan", "Aryan",
	"Kunal", "Nikhil", "Manav", "Tanish", "Harsh", "Devansh", "Om", "Parth",
	"Rehan", "Samar", "Veer", "Yuvan", "Zayan", "Ayaan",
	"Ananya", "Diya", "Aadhya", "Saanvi", "Pari", "Anika", "Navya", "Riya",
	"Meera", "Kavya", "Isha", "Sneha", "Pooja", "Neha", "Priya", "Tara",
	"Nitya", "Aarohi", "Mahi", "Siya", "Ira", "Myra", "Kiara", "Avni",
	"Rhea", "Anvi", "Trisha", "Vaani", "Zara", "Amaira",
}

var nameSuffixes = []string{
	"", "", "", "", "",
	"_07", "_99", "_11", "21", "_x", "raja", "king", "ji", "_pro", "143",
	"_gaming", "01", "_bhai", "star", "786",
}

func nameFor(number int) string {
	first := firstNames[number%len(firstNames)]
	suffix := nameSuffixes[(number/len(firstNames))%len(nameSuffixes)]
	name := first + suffix
	if len(name) > 24 { // the server's DISPLAY_NAME_MAX
		name = name[:24]
	}
	return name
}
