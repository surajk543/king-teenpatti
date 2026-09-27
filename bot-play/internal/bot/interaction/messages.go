package interaction

import (
	"regexp"
	"strings"
	"unicode"
)

// pool is a moment's lines in the two registers a bot may speak.
type pool struct {
	english  []string
	hinglish []string
}

// lines are what the bots say, by moment. The register is what people
// actually type in an Indian card room — short, mostly lowercase, Hinglish
// and English mixed (the Hinglish ported from the Node fleet's chat.js) —
// because full sentences with correct punctuation would stand out more than
// saying nothing. Nothing here names a bot, a program or the fleet, nothing
// depends on the time of day, and no line comes near the server's 140
// characters. {name} is a placeholder the caller fills (a first name); a line
// needing one is skipped when none is given.
//
// The variation lines are deliberately vague about WHICH variation was
// announced: a line naming the wrong one is worse than one that could follow
// any of the seven, and the announcement is on the felt for everyone.
var lines = map[Moment]pool{
	Join: {
		english: []string{"Hey", "Good luck", "hi all", "hello", "gl all", "hi", "lets play", "all the best",
			"hi guys", "gl", "hey all", "yo", "good luck all"},
		hinglish: []string{"namaste", "aa gaya main", "ram ram", "shuru karein", "kya haal", "aaj to jeetna hai",
			"chalo shuru", "hello ji", "sab ko namaste"},
	},
	Welcome: {
		english:  []string{"welcome {name}", "hi {name}", "hello {name}", "hey {name}", "gl {name}"},
		hinglish: []string{"aao {name}", "{name} aa gaye", "aao {name} ji", "namaste {name}"},
	},
	Win: {
		english:  []string{"Nice hand", "GG", "ty", "thanks", "nice", "thank u", "ty all", "gg all", "ok ok"},
		hinglish: []string{"chalo", "shukriya", "thoda thoda", "chalo kuch to mila", "badhiya"},
	},
	BigWin: {
		english: []string{"yesss", "finally", "thank you thank you", "thats mine", "what a pot", "lets gooo", "GG", "haha"},
		hinglish: []string{"aaj ka din acha hai", "kya baat", "ekdum", "bohot badhiya", "aa gaya maza",
			"itna wait kiya iske liye", "jai ho", "pot mera", "haha lo"},
	},
	Loss: {
		english:  []string{"Ahh", "Good one", "ok", "gg", "next", "no problem", "wp", "hmm", "nh"},
		hinglish: []string{"chalta hai", "aage dekhte hai", "koi na", "theek hai next", "chalo next"},
	},
	BigLoss: {
		english: []string{"oh no", "wow", "that hurt", "unbelievable", "bad beat", "well played", "ugh", "Ahh", "seriously"},
		hinglish: []string{"kya kismat hai", "gaya", "arre yaar", "sab chala gaya", "ufff", "aisa bhi hota hai",
			"kaise", "yaar"},
	},
	NiceHand: {
		english:  []string{"nice hand {name}", "gg {name}", "wp {name}", "Nice hand", "well played {name}"},
		hinglish: []string{"wah {name}", "kya haath tha", "itna acha haath", "wah wah"},
	},
	StrongHand: {
		english:  []string{"Let's go", "lets go", "here we go", "come on"},
		hinglish: []string{"ab maza aayega", "chalo dekhte hai", "aaj apna din hai"},
	},
	BigRaise: {
		english:  []string{"whoa", "bluff?", "hmm", "big bet", "someone is confident", "ok ok"},
		hinglish: []string{"itna bada chaal", "bluff hai kya", "dekhte hai", "confident ho", "bada khel"},
	},
	PlayingBlind: {
		english:  []string{"no peeking", "going blind", "blind it is", "not looking"},
		hinglish: []string{"blind hi chalega", "bina dekhe", "blind mein maza hai", "blind chal"},
	},
	SideshowWon: {
		english:  []string{"got you", "hehe", "sideshow mine"},
		hinglish: []string{"sideshow mera", "pakad liya"},
	},
	SideshowLost: {
		english:  []string{"fair", "ok fair", "damn"},
		hinglish: []string{"sideshow gaya", "chalo koi nahi", "theek hai"},
	},
	Packed: {
		english:  []string{"not my hand", "not this time", "im out", "pass"},
		hinglish: []string{"is baar nahi", "chhod diya", "pack"},
	},
	LowChips: {
		english:  []string{"almost broke", "chips low", "running low", "last few chips"},
		hinglish: []string{"chips khatam", "paisa khatam ho gaya", "bas itna hi"},
	},
	Leave: {
		english:  []string{"GG", "Good game", "bye", "bye all", "gtg", "gg all", "thanks all", "see you"},
		hinglish: []string{"chalo bye", "phir milte hai", "thoda break", "bye bye", "chalta hu", "kal milte hai"},
	},
	ReplyHi: {
		english:  []string{"hi", "hello", "hey", "hlo", "hii", "hey there"},
		hinglish: []string{"namaste", "haan hello", "hello ji"},
	},
	ReplyName: {
		english:  []string{"yes?", "yeah?", "what", "hmm?", "yes"},
		hinglish: []string{"haan bolo", "kya hua", "haan ji", "bolo"},
	},
	Variation: {
		english: []string{"interesting", "ok ok", "lets see", "this one is fun"},
		hinglish: []string{"ye wala acha hai", "arre wah", "dekhte hai is baar", "naya khel", "ab maza aayega",
			"is baar alag", "chalo try karte hai"},
	},
	FiveCard: {
		english:  []string{"5 cards", "so many cards", "choices choices", "which three"},
		hinglish: []string{"paanch patti", "5 card maza", "ab teen choose karo", "konsa rakhu", "choice hi choice"},
	},
}

// Lines is a copy of the templates a bot may say at m in language ("mixed" —
// both registers, English first — "english" or "hinglish"), placeholders
// unfilled.
func Lines(m Moment, language string) []string {
	p := lines[m]
	switch normaliseLanguage(language) {
	case languageEnglish:
		return append([]string(nil), p.english...)
	case languageHinglish:
		return append([]string(nil), p.hinglish...)
	}
	return append(append([]string(nil), p.english...), p.hinglish...)
}

// BigPotBoots is how many boots a pot must reach to count as big: measured
// against the table's boot, so the same excitement reads right at a 200
// table and a 50,000 one (the Node fleet's moodFor).
const BigPotBoots = 12

// ResultMoment is the moment a finished hand puts a bot in: a win or a loss,
// big when the pot reached BigPotBoots boots.
func ResultMoment(won bool, pot, boot int64) Moment {
	big := boot > 0 && pot >= boot*BigPotBoots
	switch {
	case won && big:
		return BigWin
	case won:
		return Win
	case big:
		return BigLoss
	}
	return Loss
}

// greeting is a hello in the chat: hi (hii, hiii …), hello, hey, namaste, hlo.
var greeting = regexp.MustCompile(`\b(hi+|hello|hey|namaste|hlo)\b`)

// Heard is whether a line someone else typed calls for an answer from a bot
// called myName: its first name (three letters or more) anywhere in it is
// ReplyName, a greeting is ReplyHi. Whether the speaker is a person or
// another bot of the fleet is the caller's to weigh (MaybeScaled).
func Heard(text, myName string) (Moment, bool) {
	lower := strings.ToLower(text)
	if name := strings.ToLower(FirstName(myName)); len([]rune(name)) >= 3 && strings.Contains(lower, name) {
		return ReplyName, true
	}
	if greeting.MatchString(lower) {
		return ReplyHi, true
	}
	return "", false
}

// FirstName is the part of a display name a person would use in chat: its
// first word, without trailing punctuation ("Ravi Kumar" → "Ravi", "Ravi,"
// → "Ravi"; "Guest8D049" stays as it is).
func FirstName(display string) string {
	fields := strings.Fields(display)
	if len(fields) == 0 {
		return ""
	}
	first := strings.TrimRightFunc(fields[0], func(r rune) bool { return unicode.IsPunct(r) })
	if first == "" {
		return fields[0]
	}
	return first
}
