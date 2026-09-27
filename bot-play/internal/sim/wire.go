package sim

import (
	"encoding/json"

	"github.com/surajk543/king-teenpatti/bot-play/internal/protocol"
)

// The JSON the simulation sends. Each type mirrors its namesake in the real
// server — go-server/internal/game/view.go (the per-viewer snapshot),
// internal/game/events.go and internal/socket/wire.go — key for key, null
// for null, absent for absent, so a client decodes it exactly as it decodes
// the server's. Where the bots' own copy (internal/protocol) already has the
// server's exact shape, it is reused.

// roomStateWire is room:state / room:joined (game.TableView).
type roomStateWire struct {
	RoomID        string                  `json:"roomId"`
	Code          string                  `json:"code"`
	IsPrivate     bool                    `json:"isPrivate"`
	TablePicture  *struct{}               `json:"tablePicture"`
	Category      string                  `json:"category"`
	ChipsHidden   bool                    `json:"chipsHidden"`
	State         string                  `json:"state"`
	HandNo        int                     `json:"handNo"`
	DealerSeat    int                     `json:"dealerSeat"`
	MaxPlayers    int                     `json:"maxPlayers"`
	MinPlayers    int                     `json:"minPlayers"`
	BootAmount    int64                   `json:"bootAmount"`
	TurnTimeoutMs int64                   `json:"turnTimeoutMs"`
	StartsAt      *int64                  `json:"startsAt"`
	Pot           int64                   `json:"pot"`
	MaxPot        int64                   `json:"maxPot"`
	Stake         int64                   `json:"stake"`
	Round         int                     `json:"round"`
	Sideshow      *protocol.SideshowView  `json:"sideshow"`
	Variation     *protocol.VariationView `json:"variation,omitempty"`
	Turn          *protocol.TurnView      `json:"turn"`
	You           *youWire                `json:"you"`
	Seats         []seatWire              `json:"seats"`
}

// youWire is TableView.you (game.YouView).
type youWire struct {
	SeatIndex      int                   `json:"seatIndex"`
	Chips          int64                 `json:"chips"`
	Status         string                `json:"status"`
	IsBlind        bool                  `json:"isBlind"`
	BlindMovesLeft int                   `json:"blindMovesLeft"`
	Contributed    int64                 `json:"contributed"`
	MissedTurns    int                   `json:"missedTurns"`
	MaxMissedTurns int                   `json:"maxMissedTurns"`
	CanMissile     bool                  `json:"canMissile"`
	Cards          []string              `json:"cards"`
	Options        *protocol.TurnOptions `json:"options"`
	Hand           *protocol.YouHand     `json:"hand,omitempty"`
}

// seatWire is one of TableView.seats (game.SeatView): an empty seat is
// exactly {seatIndex, status:"empty"}.
type seatWire struct {
	empty       bool
	SeatIndex   int     `json:"seatIndex"`
	UserID      string  `json:"userId"`
	DisplayName string  `json:"displayName"`
	AvatarURL   *string `json:"avatarUrl"`
	Chips       *int64  `json:"chips"`
	Status      string  `json:"status"`
	IsBlind     bool    `json:"isBlind"`
	LastBet     int64   `json:"lastBet"`
	LastAction  *string `json:"lastAction"`
	Contributed int64   `json:"contributed"`
	Connected   bool    `json:"connected"`
	CardCount   int     `json:"cardCount"`
}

type seatWireFull seatWire

// MarshalJSON writes the two-key form for an empty seat.
func (s seatWire) MarshalJSON() ([]byte, error) {
	if s.empty {
		return json.Marshal(struct {
			SeatIndex int    `json:"seatIndex"`
			Status    string `json:"status"`
		}{s.SeatIndex, protocol.SeatEmpty})
	}
	return json.Marshal(seatWireFull(s))
}

type handStartedWire struct {
	HandID       string   `json:"handId"`
	HandNo       int      `json:"handNo"`
	DealerSeat   int      `json:"dealerSeat"`
	BootAmount   int64    `json:"bootAmount"`
	Pot          int64    `json:"pot"`
	Stake        int64    `json:"stake"`
	Participants []string `json:"participants"`
	RoomID       string   `json:"roomId"`
}

type turnWire struct {
	RoomID    string `json:"roomId"`
	UserID    string `json:"userId"`
	SeatIndex int    `json:"seatIndex"`
	Deadline  int64  `json:"deadline"`
	TimeoutMs int64  `json:"timeoutMs"`
}

type revealWire struct {
	UserID    string   `json:"userId"`
	SeatIndex int      `json:"seatIndex"`
	Cards     []string `json:"cards"`
	HandName  string   `json:"handName"`
	Category  int      `json:"category"`
	Won       bool     `json:"won"`
}

type showdownWire struct {
	Reveals   []revealWire `json:"reveals"`
	Reason    string       `json:"reason"`
	Variation string       `json:"variation,omitempty"`
	RoomID    string       `json:"roomId"`
}

type handEndedWire struct {
	HandID     string       `json:"handId"`
	HandNo     int          `json:"handNo"`
	WinnerID   *string      `json:"winnerId"`
	WinnerName *string      `json:"winnerName"`
	Pot        int64        `json:"pot"`
	Reason     string       `json:"reason"`
	Reveals    []revealWire `json:"reveals"`
	NextHandAt int64        `json:"nextHandAt"`
	Variation  string       `json:"variation,omitempty"`
	RoomID     string       `json:"roomId"`
}

type sideshowRequestedWire struct {
	FromUserID string `json:"fromUserId"`
	FromName   string `json:"fromName"`
	FromSeat   int    `json:"fromSeat"`
	ToUserID   string `json:"toUserId"`
	ToName     string `json:"toName"`
	ToSeat     int    `json:"toSeat"`
	ExpiresAt  int64  `json:"expiresAt"`
	TimeoutMs  int64  `json:"timeoutMs"`
	RoomID     string `json:"roomId"`
}

type sideshowHandWire struct {
	UserID      string   `json:"userId"`
	DisplayName string   `json:"displayName"`
	Cards       []string `json:"cards"`
	HandName    string   `json:"handName"`
}

type sideshowRevealWire struct {
	RoomID string `json:"roomId"`
	Reveal struct {
		Reason       string             `json:"reason"`
		PackedUserID string             `json:"packedUserId"`
		Hands        []sideshowHandWire `json:"hands"`
	} `json:"reveal"`
}

type variationSelectingWire struct {
	UserID      string   `json:"userId"`
	DisplayName string   `json:"displayName"`
	SeatIndex   int      `json:"seatIndex"`
	StartedAt   int64    `json:"startedAt"`
	Deadline    *int64   `json:"deadline"`
	TimeoutMs   int64    `json:"timeoutMs"`
	Options     []string `json:"options"`
	RoomID      string   `json:"roomId"`
}

type variationSelectedWire struct {
	UserID         string `json:"userId"`
	DisplayName    string `json:"displayName"`
	SeatIndex      int    `json:"seatIndex"`
	Variation      string `json:"variation"`
	SelectedBy     string `json:"selectedBy"`
	CardsPerPlayer int    `json:"cardsPerPlayer"`
	RoomID         string `json:"roomId"`
}

type chatWire struct {
	ID          string  `json:"id"`
	UserID      *string `json:"userId"`
	DisplayName string  `json:"displayName"`
	Text        string  `json:"text"`
	At          int64   `json:"at"`
	System      bool    `json:"system,omitempty"`
	RoomID      string  `json:"roomId"`
}

type roomIDWire struct {
	RoomID string `json:"roomId"`
}

type messageWire struct {
	Message string `json:"message"`
}

type gameErrorWire struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type disconnectWire struct {
	Reason string `json:"reason"`
}

type sessionReadyWire struct {
	User   protocol.User         `json:"user"`
	Config configWire            `json:"config"`
	Resume *protocol.ResumeOffer `json:"resume,omitempty"`
}

// configWire is session:ready.config (socket.PublicGameConfig).
type configWire struct {
	MaxPlayers         int        `json:"maxPlayers"`
	MinPlayers         int        `json:"minPlayers"`
	BootAmount         int64      `json:"bootAmount"`
	TurnTimeoutMs      int64      `json:"turnTimeoutMs"`
	WelcomeChips       int64      `json:"welcomeChips"`
	MaxBetRounds       int        `json:"maxBetRounds"`
	SideshowTimeoutMs  int64      `json:"sideshowTimeoutMs"`
	SideshowMinPlayers int        `json:"sideshowMinPlayers"`
	MinClientBuild     int        `json:"minClientBuild"`
	TableConfigVersion string     `json:"tableConfigVersion"`
	Categories         []string   `json:"categories"`
	Stakes             []int64    `json:"stakes"`
	Tables             []menuWire `json:"tables"`
	PrivateBoot        int64      `json:"privateBoot"`
	PrivateMaxPot      int64      `json:"privateMaxPot"`
}

// menuWire is one of session:ready.config.tables (game.LobbyTable's keys).
type menuWire struct {
	Category      string `json:"category"`
	BootAmount    int64  `json:"bootAmount"`
	MaxPot        int64  `json:"maxPot"`
	MaxBlindMoves int    `json:"maxBlindMoves"`
	MinChips      int64  `json:"minChips"`
	MaxChips      int64  `json:"maxChips"`
}

// ---- acks ----

type errorAck struct {
	OK      bool   `json:"ok"`
	Code    string `json:"code"`
	Message string `json:"message"`
}

type okAck struct {
	OK bool `json:"ok"`
}

type roomAck struct {
	OK       bool   `json:"ok"`
	RoomID   string `json:"roomId"`
	Code     string `json:"code"`
	Category string `json:"category"`
}

type leaveAck struct {
	OK     bool   `json:"ok"`
	RoomID string `json:"roomId"`
}

type actionAck struct {
	OK       bool   `json:"ok"`
	Action   string `json:"action"`
	Auto     *bool  `json:"auto,omitempty"`
	Amount   *int64 `json:"amount,omitempty"`
	AutoSeen *bool  `json:"autoSeen,omitempty"`
	Reason   string `json:"reason,omitempty"`
	ToUserID string `json:"toUserId,omitempty"`
}

type sideshowAck struct {
	OK           bool    `json:"ok"`
	Accepted     bool    `json:"accepted"`
	PackedUserID *string `json:"packedUserId"`
}

type variationAck struct {
	OK             bool   `json:"ok"`
	Variation      string `json:"variation"`
	SelectedBy     string `json:"selectedBy"`
	CardsPerPlayer int    `json:"cardsPerPlayer"`
}

type chatAck struct {
	OK        bool   `json:"ok"`
	MessageID string `json:"messageId"`
}
