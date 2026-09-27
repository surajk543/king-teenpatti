package interaction

import "context"

// Emoter sends an animated emote for a moment. The server's chat:emoji needs
// an emoji the account OWNS (bought with hammers or diamonds), and the bots
// buy nothing, so the fleet runs with NoEmotes; a version that buys and
// sends emojis connects here without touching the rest.
type Emoter interface {
	Emote(ctx context.Context, m Moment) error
}

// NoEmotes sends nothing.
type NoEmotes struct{}

// Emote does nothing and reports no error.
func (NoEmotes) Emote(context.Context, Moment) error { return nil }
