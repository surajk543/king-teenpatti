// Package protocol is the game server's public client protocol, as the bots
// speak it: the Socket.IO event names, the refusal codes, and the JSON the
// server sends, written as Go types.
//
// Everything here mirrors go-server/internal/socket/wire.go and
// go-server/internal/game/view.go (the per-viewer snapshot). It is a CLIENT'S
// copy of the contract — the same thing the Flutter app's dtos.dart is — and
// holds no rule of the game: the server deals, validates every move against
// the ladder it computes and decides every winner. A bot only reads what a
// player at that seat is shown and sends what a player could send.
//
// Decoding is tolerant, as the Flutter client's is: a field the server adds
// later is ignored, one it leaves out reads as the zero value, and a figure
// the server sends as null reads as a nil pointer, never as 0.
package protocol

// Client → server events (go-server/internal/socket/wire.go).
const (
	EvRoomQuickJoin       = "room:quickJoin"       // {bootAmount, category} → RoomAck
	EvRoomJoinCode        = "room:joinCode"        // {code} → RoomAck (a resume offer)
	EvRoomSwitch          = "room:switch"          // {} → RoomAck
	EvRoomLeave           = "room:leave"           // {} → LeaveAck
	EvGameAction          = "game:action"          // ActionRequest → ActionAck
	EvGameSideshowRespond = "game:sideshowRespond" // {accept} → Ack
	EvGameSelectVariation = "game:selectVariation" // {variation} → Ack
	EvGameSelectCards     = "game:selectCards"     // {cards:[3]} → Ack
	EvChatMessage         = "chat:message"         // {text} → Ack (also inbound)
	EvChatEmoji           = "chat:emoji"           // {emojiId} → Ack (the emoji must be owned)
)

// Server → client events.
const (
	EvSessionReady           = "session:ready"    // SessionReady
	EvSessionReplaced        = "session:replaced" // this socket was replaced by a newer one
	EvRoomJoined             = "room:joined"      // RoomState
	EvRoomState              = "room:state"       // RoomState, per viewer
	EvRoomMoved              = "room:moved"       // RoomMoved; the room:joined that follows carries the state
	EvRoomLeft               = "room:left"        // {roomId}
	EvRoomClosed             = "room:closed"      // {roomId}
	EvRoomKicked             = "room:kicked"      // RoomKicked
	EvGameHandStarted        = "game:handStarted" // room
	EvGameTurn               = "game:turn"        // room, no options
	EvGameYourTurn           = "game:yourTurn"    // YourTurn, the player on turn only
	EvGameActionOut          = "game:action"      // ActionEvent, room (same name as the inbound event)
	EvGameSideshowRequested  = "game:sideshowRequested"
	EvGameSideshowReveal     = "game:sideshowReveal" // the two players only
	EvGameSideshowResolved   = "game:sideshowResolved"
	EvGameVariationSelecting = "game:variationSelecting"
	EvGameVariationSelected  = "game:variationSelected"
	EvGameShowdown           = "game:showdown" // Showdown
	EvGameHandEnded          = "game:handEnded"
	EvGameError              = "game:error" // Ack-shaped {code, message}
	EvPlayerLevel            = "player:level"
)

// Engine.IO / Socket.IO transport events a Session reports alongside the
// server's own: the connection's end is an event like any other, so a bot's
// one loop sees it in order with everything else.
const (
	EvDisconnect   = "disconnect"    // the connection ended; Session.Err says why
	EvConnectError = "connect_error" // the handshake was refused: {message}
)

// Category is a table's game: the three Teen Patti ones the bots play.
const (
	CategorySeen      = "seen"
	CategoryBlind     = "blind"
	CategoryVariation = "variation"
)

// EngineTeenPatti is the only engine the bots play (GET /api/tables' engine).
const EngineTeenPatti = "teen_patti"

// Table states (room:state.state).
const (
	TableWaiting  = "waiting"
	TableStarting = "starting"
	TableBetting  = "betting"
	TableShowdown = "showdown"
)

// Seat states (seats[].status, you.status).
const (
	SeatEmpty   = "empty"
	SeatWaiting = "waiting" // seated, sitting this hand out
	SeatActive  = "active"  // in the hand and still betting
	SeatPacked  = "packed"
	SeatLost    = "lost"
	SeatWon     = "won"
)

// Moves (game:action.action).
const (
	ActionSee           = "see"
	ActionChaal         = "chaal"
	ActionRaise         = "raise"
	ActionPack          = "pack"
	ActionShow          = "show"
	ActionSideshow      = "sideshow"
	ActionForceSideshow = "forceSideshow" // costs a hammer; bots never use it
	ActionMissile       = "missile"       // costs a missile; bots never use it
)

// Variations (variation.options / selected), in the server's order.
const (
	VariationMuflis       = "MUFLIS"
	VariationAK47         = "AK47"
	VariationJoker        = "JOKER"
	VariationHukam        = "HUKAM"
	VariationLowestJoker  = "LOWEST_JOKER"
	VariationHighestJoker = "HIGHEST_JOKER"
	VariationFiveCard     = "FIVE_CARD"
)

// Hand categories (you.hand.category, reveals[].category): HighCard 0 … Trail 5.
const (
	HandHighCard     = 0
	HandPair         = 1
	HandColor        = 2
	HandSequence     = 3
	HandPureSequence = 4
	HandTrail        = 5
)

// Win reasons (game:showdown.reason, game:handEnded.reason).
const (
	WinLastStanding   = "last_standing"
	WinShow           = "show"
	WinForcedShowdown = "forced_showdown"
	WinAllLeft        = "all_left"
	WinPotLimit       = "pot_limit"
	WinMissile        = "missile"
)

// Refusal codes the bots act on ({ok:false, code, message}). Compared by
// code, never by message.
const (
	CodeAlreadyInRoom     = "already_in_room"
	CodeTableFull         = "table_full"
	CodeInsufficientChips = "insufficient_chips"
	CodeOverEntryCap      = "over_entry_cap"
	CodeBelowTableMinimum = "below_table_minimum"
	CodeTableNotOffered   = "table_not_offered"
	CodeInvalidStake      = "invalid_stake"
	CodeSettlementPending = "settlement_pending"
	CodeNotInRoom         = "not_in_room"
	CodeNotYourTurn       = "not_your_turn"
	CodeNoHand            = "no_hand"
	CodeNotInHand         = "not_in_hand"
	CodeInvalidBet        = "invalid_bet"
	CodeDuplicateAction   = "duplicate_action"
	CodeAlreadySeen       = "already_seen"
	CodeSideshowPending   = "sideshow_pending"
	CodePickPending       = "pick_pending"
	CodeVariationPending  = "variation_pending"
	CodeRateLimited       = "rate_limited"
	CodeChatRateLimited   = "chat_rate_limited"
	CodeNoOtherTable      = "no_other_table"
	CodeInvalidRoomCode   = "invalid_room_code"
	CodeRoomNotFound      = "room_not_found"
	CodeSeated            = "seated"
	CodeUnknownUser       = "unknown_user"
	CodeInvalidSession    = "invalid_session"
	CodeAccountDisabled   = "account_disabled"
	CodeProviderDisabled  = "provider_unconfigured"
	CodeMissingToken      = "missing_token"
	CodeUnauthorized      = "unauthorized"
	CodeInvalidVariation  = "invalid_variation"
	CodeVariationExpired  = "variation_expired"
	CodeVariationSelected = "variation_already_selected"
	CodeNotSelecting      = "not_selecting"
	CodeNotPicking        = "not_picking"
	CodeInvalidPick       = "invalid_pick"
	CodeShowUnavailable   = "show_unavailable"
	CodeNoSideshow        = "no_sideshow"
)

// Ack is every acknowledgement's common part: {ok:true, …} or
// {ok:false, code, message}. A request that is refused also arrives as a
// game:error event (the server reports a refusal twice; clients dedupe).
type Ack struct {
	OK      bool   `json:"ok"`
	Code    string `json:"code,omitempty"`
	Message string `json:"message,omitempty"`
}

// RoomAck answers room:quickJoin / joinCode / switch. On success the ack's
// "code" key (Ack.Code) is the TABLE's code; on a refusal it is the refusal
// code — read OK first.
type RoomAck struct {
	Ack
	RoomID   string `json:"roomId"`
	Category string `json:"category"`
}

// ActionRequest is game:action's payload. ActionID (≤ 64 characters) is the
// idempotency key: the server refuses a second move with the same id in the
// same hand (duplicate_action), so a resend after a reconnect cannot bet twice.
type ActionRequest struct {
	Action   string `json:"action"`
	Amount   *int64 `json:"amount,omitempty"`
	ActionID string `json:"actionId"`
}

// ActionAck answers game:action.
type ActionAck struct {
	Ack
	Action string `json:"action,omitempty"`
	Amount int64  `json:"amount,omitempty"`
}

// User is the account as the server returns it (login, session:ready,
// /api/auth/me). Only what a bot reads.
type User struct {
	ID              string  `json:"id"`
	DisplayName     string  `json:"displayName"`
	Chips           int64   `json:"chips"`
	ActivePictureID *int64  `json:"activePictureId"`
	Rewards         Rewards `json:"rewards"`
}

// Rewards is user.rewards: when the 4-hour bonus can next be collected.
type Rewards struct {
	BonusReadyAt int64 `json:"bonusReadyAt"` // epoch ms; 0 or past = ready
}

// LoginResult is POST /api/auth/login's answer.
type LoginResult struct {
	Token        string `json:"token"`
	User         User   `json:"user"`
	IsNew        bool   `json:"isNew"`
	WelcomeChips int64  `json:"welcomeChips"`
}

// SessionReady is session:ready: the account, the table-wide config, and a
// resume offer when a seat this account lost to the reconnect grace can
// still be taken back (room:joinCode with its code).
type SessionReady struct {
	User   User          `json:"user"`
	Config SessionConfig `json:"config"`
	Resume *ResumeOffer  `json:"resume,omitempty"`
}

// SessionConfig is the part of session:ready.config a bot reads.
type SessionConfig struct {
	TurnTimeoutMs      int64        `json:"turnTimeoutMs"`
	TableConfigVersion string       `json:"tableConfigVersion"`
	Tables             []TableEntry `json:"tables"`
}

// ResumeOffer is session:ready.resume.
type ResumeOffer struct {
	RoomID     string `json:"roomId"`
	Code       string `json:"code"`
	Category   string `json:"category"`
	BootAmount int64  `json:"bootAmount"`
}

// Catalogue is GET /api/tables — the table menu the server enforces.
type Catalogue struct {
	Version       string       `json:"version"`
	TurnTimeoutMs int64        `json:"turnTimeoutMs"`
	MaxPlayers    int          `json:"maxPlayers"`
	Tables        []TableEntry `json:"tables"`
}

// TableEntry is one lobby table of the catalogue (and of
// session:ready.config.tables, which carries a subset of these keys).
type TableEntry struct {
	Key           string `json:"key"`    // "seen:200"; absent in session:ready — use Category and BootAmount
	Engine        string `json:"engine"` // "teen_patti" | "poker"; absent in session:ready
	Category      string `json:"category"`
	BootAmount    int64  `json:"bootAmount"`
	MinChips      int64  `json:"minChips"` // the stack band: 0 = no floor
	MaxChips      int64  `json:"maxChips"` // 0 = no ceiling
	MaxPot        int64  `json:"maxPot"`
	MaxBlindMoves int    `json:"maxBlindMoves"`
	IsPrivate     bool   `json:"isPrivate"`
	SortOrder     int    `json:"sortOrder"`
	TurnTimeoutMs int64  `json:"turnTimeoutMs"`
	WinnerTax     bool   `json:"winnerTax"`
}

// RoomState is room:state / room:joined: the table as THIS viewer is allowed
// to see it. Other players' cards are never in it; on blind and variation
// tables other players' chips are null.
type RoomState struct {
	RoomID        string         `json:"roomId"`
	Code          string         `json:"code"`
	IsPrivate     bool           `json:"isPrivate"`
	Category      string         `json:"category"`
	ChipsHidden   bool           `json:"chipsHidden"`
	State         string         `json:"state"`
	HandNo        int            `json:"handNo"`
	DealerSeat    int            `json:"dealerSeat"`
	MaxPlayers    int            `json:"maxPlayers"`
	MinPlayers    int            `json:"minPlayers"`
	BootAmount    int64          `json:"bootAmount"`
	TurnTimeoutMs int64          `json:"turnTimeoutMs"`
	StartsAt      *int64         `json:"startsAt"`
	Pot           int64          `json:"pot"`
	MaxPot        int64          `json:"maxPot"`
	Stake         int64          `json:"stake"`
	Round         int            `json:"round"`
	Sideshow      *SideshowView  `json:"sideshow"`
	Variation     *VariationView `json:"variation,omitempty"` // absent on seen and blind tables
	Turn          *TurnView      `json:"turn"`
	You           *You           `json:"you"`
	Seats         []Seat         `json:"seats"`
}

// SideshowView is room:state.sideshow: a request waiting for its answer.
type SideshowView struct {
	FromUserID string `json:"fromUserId"`
	FromSeat   int    `json:"fromSeat"`
	ToUserID   string `json:"toUserId"`
	ToSeat     int    `json:"toSeat"`
	ExpiresAt  int64  `json:"expiresAt"`
}

// VariationView is room:state.variation on a variation table's hand.
type VariationView struct {
	Selecting      bool     `json:"selecting"`
	UserID         string   `json:"userId"`
	DisplayName    string   `json:"displayName"`
	SeatIndex      int      `json:"seatIndex"`
	StartedAt      int64    `json:"startedAt"`
	Deadline       *int64   `json:"deadline"`
	TimeoutMs      int64    `json:"timeoutMs"`
	Options        []string `json:"options"`
	Selected       *string  `json:"selected"`
	SelectedBy     *string  `json:"selectedBy"`
	TurnUp         *string  `json:"turnUp,omitempty"`
	CardsPerPlayer int      `json:"cardsPerPlayer"`
}

// TurnView is room:state.turn: whose turn it is. SeatIndex is -1 while
// nobody is on turn (a variation window, a deferred showdown).
type TurnView struct {
	SeatIndex int     `json:"seatIndex"`
	UserID    *string `json:"userId"`
	Deadline  *int64  `json:"deadline"`
}

// You is room:state.you: this viewer's own seat, with what only they see.
type You struct {
	SeatIndex        int          `json:"seatIndex"`
	Chips            int64        `json:"chips"`
	Status           string       `json:"status"`
	IsBlind          bool         `json:"isBlind"`
	BlindMovesLeft   int          `json:"blindMovesLeft"`
	Contributed      int64        `json:"contributed"`
	MissedTurns      int          `json:"missedTurns"`
	MaxMissedTurns   int          `json:"maxMissedTurns"`
	UnfundedDeadline *int64       `json:"unfundedDeadline,omitempty"`
	Cards            []string     `json:"cards"`   // empty while blind
	Options          *TurnOptions `json:"options"` // present only while it is this viewer's turn
	Hand             *YouHand     `json:"hand,omitempty"`
}

// YouHand is you.hand on a variation table: the viewer's own hand as the
// chosen variation counts it — the server's evaluation, so the bots never
// re-implement the wild-card rules. Present once the viewer has seen AND the
// variation is chosen. While Picking (5-Card, choosing three of five) the
// name, category and best are deliberately empty.
type YouHand struct {
	HandName      string   `json:"handName"`
	Category      int      `json:"category"`
	Wild          []string `json:"wild"`
	PlaysAs       []string `json:"playsAs"`
	Best          []string `json:"best"`
	Picking       bool     `json:"picking,omitempty"`
	PickDeadline  int64    `json:"pickDeadline,omitempty"`
	PickTimeoutMs int64    `json:"pickTimeoutMs,omitempty"`
	PickedBy      string   `json:"pickedBy,omitempty"`
	BestPossible  []string `json:"bestPossible,omitempty"`
}

// TurnOptions is you.options (and game:yourTurn.options): what the SERVER
// will accept from this player now. A move outside it is refused.
//
// RaiseSteps is the ladder: RaiseSteps[0] is the chaal, and a raise must be
// exactly one of the later rungs (at least twice the first). An empty ladder
// means no bet is affordable (or the pot cap leaves no room): only pack, a
// show or a sideshow remain.
type TurnOptions struct {
	CanSee           bool    `json:"canSee"`
	CanSideshow      bool    `json:"canSideshow"`
	SideshowWith     *string `json:"sideshowWith"`
	CanForceSideshow bool    `json:"canForceSideshow"`
	CanMissile       bool    `json:"canMissile"`
	Chaal            *int64  `json:"chaal"`
	Raise            *int64  `json:"raise"`
	RaiseSteps       []int64 `json:"raiseSteps"`
	MaxBet           *int64  `json:"maxBet"`
	Show             *int64  `json:"show"`
	CanPack          bool    `json:"canPack"`
	IsBlind          bool    `json:"isBlind"`
	CurrentStake     int64   `json:"currentStake"`
	Chips            int64   `json:"chips"`
	Pot              int64   `json:"pot"`
}

// Seat is one entry of room:state.seats. An empty seat has status "empty"
// and no user id. Chips is nil where the table hides other players' stacks.
type Seat struct {
	SeatIndex   int     `json:"seatIndex"`
	UserID      string  `json:"userId"`
	DisplayName string  `json:"displayName"`
	Chips       *int64  `json:"chips"`
	Status      string  `json:"status"`
	IsBlind     bool    `json:"isBlind"`
	LastBet     int64   `json:"lastBet"`
	LastAction  *string `json:"lastAction"`
	Contributed int64   `json:"contributed"`
	Connected   bool    `json:"connected"`
	CardCount   int     `json:"cardCount"`
	Picking     bool    `json:"picking,omitempty"`
}

// YourTurn is game:yourTurn. The bots act on room:state's you.options (the
// snapshot is the authority, as it is for the Flutter client) and use this
// only for its deadline.
type YourTurn struct {
	RoomID    string      `json:"roomId"`
	Deadline  int64       `json:"deadline"`
	TimeoutMs int64       `json:"timeoutMs"`
	Options   TurnOptions `json:"options"`
}

// ActionEvent is the room's game:action broadcast: somebody moved.
type ActionEvent struct {
	RoomID string `json:"roomId"`
	UserID string `json:"userId"`
	Action string `json:"action"`
	Amount int64  `json:"amount"`
	Auto   *bool  `json:"auto,omitempty"`
	Pot    int64  `json:"pot"`
	Stake  int64  `json:"stake"`
	Reason string `json:"reason,omitempty"`
}

// SideshowRequested is game:sideshowRequested.
type SideshowRequested struct {
	RoomID     string `json:"roomId"`
	FromUserID string `json:"fromUserId"`
	FromName   string `json:"fromName"`
	ToUserID   string `json:"toUserId"`
	ToName     string `json:"toName"`
	ExpiresAt  int64  `json:"expiresAt"`
	TimeoutMs  int64  `json:"timeoutMs"`
}

// SideshowResolved is game:sideshowResolved.
type SideshowResolved struct {
	RoomID       string  `json:"roomId"`
	FromUserID   string  `json:"fromUserId"`
	ToUserID     string  `json:"toUserId"`
	Accepted     bool    `json:"accepted"`
	Reason       string  `json:"reason"`
	PackedUserID *string `json:"packedUserId"`
}

// Reveal is one player's cards at a showdown.
type Reveal struct {
	UserID   string   `json:"userId"`
	Cards    []string `json:"cards"`
	HandName string   `json:"handName"`
	Category int      `json:"category"`
	Won      bool     `json:"won"`
	Best     []string `json:"best,omitempty"`
}

// Showdown is game:showdown.
type Showdown struct {
	RoomID    string   `json:"roomId"`
	Reveals   []Reveal `json:"reveals"`
	Reason    string   `json:"reason"`
	Variation string   `json:"variation,omitempty"`
}

// HandEnded is game:handEnded.
type HandEnded struct {
	RoomID     string   `json:"roomId"`
	HandID     string   `json:"handId"`
	HandNo     int      `json:"handNo"`
	WinnerID   *string  `json:"winnerId"`
	WinnerName *string  `json:"winnerName"`
	Pot        int64    `json:"pot"`
	Reason     string   `json:"reason"`
	Reveals    []Reveal `json:"reveals"`
	NextHandAt int64    `json:"nextHandAt"`
	Variation  string   `json:"variation,omitempty"`
	Tax        int64    `json:"tax,omitempty"`
}

// RoomKicked is room:kicked: the server showed this player out.
// Reason is "idle" (missed turns) or "insufficient_chips" among others.
type RoomKicked struct {
	RoomID  string `json:"roomId"`
	Reason  string `json:"reason"`
	Message string `json:"message"`
}

// RoomMoved is room:moved (a consolidation or a switch moved this player).
type RoomMoved struct {
	FromRoomID string `json:"fromRoomId"`
	ToRoomID   string `json:"toRoomId"`
	Code       string `json:"code"`
	Message    string `json:"message"`
}

// ChatMessage is an inbound chat:message. UserID is nil on a line the table
// wrote itself (joined, left).
type ChatMessage struct {
	RoomID      string  `json:"roomId"`
	ID          string  `json:"id"`
	UserID      *string `json:"userId"`
	DisplayName string  `json:"displayName"`
	Text        string  `json:"text"`
	At          int64   `json:"at"`
	System      bool    `json:"system,omitempty"`
}
