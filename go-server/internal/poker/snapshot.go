package poker

import (
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/game"
)

// Snapshot is a poker room as the LIVE STORE remembers it: everything a
// lossless restore needs, hole cards, the deck stub and the dealer's hand
// included. Server-side only — NEVER sent to a client. `game` is the FIRST
// key and always "poker": RoomManager.Restore peeks at it before choosing a
// parser, which is what keeps a poker document out of the Teen Patti path
// (POKER_PLAN.md §9 risk 1).
type Snapshot struct {
	Game       game.Game       `json:"game"`
	RoomID     string          `json:"roomId"`
	Code       string          `json:"code"`
	Category   game.Category   `json:"category"`
	State      game.TableState `json:"state"`
	HandNo     int             `json:"handNo"`
	Button     int             `json:"button"`
	Hand       *SnapshotHand   `json:"hand"`
	Seats      []*SnapshotSeat `json:"seats"`
	Seq        int64           `json:"seq"`
	Version    int64           `json:"version"`
	IsPrivate  bool            `json:"isPrivate"`
	CreatedAt  int64           `json:"createdAt"`
	Config     SnapshotConfig  `json:"config"`
	StartsAt   *int64          `json:"startsAt"`
	LastResult *ResultView     `json:"lastResult,omitempty"`
}

// SnapshotConfig is Config in JSON.
type SnapshotConfig struct {
	Category        game.Category `json:"category"`
	Variant         Variant       `json:"variant"`
	BootAmount      int64         `json:"bootAmount"`
	MaxPlayers      int           `json:"maxPlayers"`
	MinPlayers      int           `json:"minPlayers"`
	TurnTimeoutMs   int64         `json:"turnTimeoutMs"`
	NextHandDelayMs int64         `json:"nextHandDelayMs"`
	UnfundedGraceMs int64         `json:"unfundedGraceMs"`
	MaxMissedTurns  int           `json:"maxMissedTurns"`
	MinBuyIn        int64         `json:"minBuyIn"`
	MaxDiscards     int           `json:"maxDiscards"`
	ChatMaxHistory  int           `json:"chatMaxHistory"`
	ChatMaxLength   int           `json:"chatMaxLength"`
}

// SnapshotSeat is one occupied seat.
type SnapshotSeat struct {
	SeatIndex     int            `json:"seatIndex"`
	UserID        string         `json:"userId"`
	DisplayName   string         `json:"displayName"`
	AvatarURL     *string        `json:"avatarUrl"`
	Chips         int64          `json:"chips"`
	Status        game.SeatState `json:"status"`
	Cards         []string       `json:"cards"`
	Contributed   int64          `json:"contributed"`
	StreetBet     int64          `json:"streetBet"`
	AllIn         bool           `json:"allIn"`
	Acted         bool           `json:"acted"`
	Drew          bool           `json:"drew"`
	Played        bool           `json:"played"`
	MissedTurns   int            `json:"missedTurns"`
	LastAction    *Action        `json:"lastAction"`
	KickPending   bool           `json:"kickPending"`
	UnfundedUntil *int64         `json:"unfundedUntil,omitempty"`
	JoinedAt      int64          `json:"joinedAt"`
}

// SnapshotHand is the live hand.
type SnapshotHand struct {
	ID            string                 `json:"id"`
	HandNo        int                    `json:"handNo"`
	StartedAt     int64                  `json:"startedAt"`
	Pot           int64                  `json:"pot"`
	Streets       []Street               `json:"streets"`
	StreetIndex   int                    `json:"streetIndex"`
	Deck          []string               `json:"deck"`
	Community     []string               `json:"community"`
	DealerCards   []string               `json:"dealerCards"`
	Button        int                    `json:"button"`
	CurrentBet    int64                  `json:"currentBet"`
	MinRaise      int64                  `json:"minRaise"`
	TurnSeat      int                    `json:"turnSeat"`
	TurnDeadline  *int64                 `json:"turnDeadline"`
	Contributions []SnapshotContribution `json:"contributions"`
	ActionIDs     []string               `json:"actionIds"`
	LastDeparture *string                `json:"lastDeparture"`
}

// SnapshotContribution is one entry of SnapshotHand.contributions.
type SnapshotContribution struct {
	UserID       string         `json:"userId"`
	DisplayName  string         `json:"displayName"`
	SeatIndex    int            `json:"seatIndex"`
	Contributed  int64          `json:"contributed"`
	Status       game.SeatState `json:"status"`
	Cards        []string       `json:"cards"`
	Played       bool           `json:"played"`
	Folded       bool           `json:"folded"`
	LeftMidHand  bool           `json:"leftMidHand"`
	AllIn        bool           `json:"allIn"`
	Won          int64          `json:"won"`
	Chips        int64          `json:"chips"`
	ChipsWritten int64          `json:"chipsWritten"`
}

// snapshot builds the document from the actor state. Actor only.
func (t *Table) snapshot() *Snapshot {
	seats := make([]*SnapshotSeat, len(t.seats))
	for i, s := range t.seats {
		if s == nil {
			continue
		}
		entry := &SnapshotSeat{
			SeatIndex: i, UserID: s.userID, DisplayName: s.displayName, Chips: s.chips, Status: s.status,
			Cards: game.CardCodes(s.cards), Contributed: s.contributed, StreetBet: s.streetBet, AllIn: s.allIn,
			Acted: s.acted, Drew: s.drew, Played: s.played, MissedTurns: s.missedTurns, KickPending: s.kickPending,
			JoinedAt: game.Millis(s.joinedAt),
		}
		if s.avatarURL != nil {
			entry.AvatarURL = game.StrPtr(*s.avatarURL)
		}
		if s.lastAction != nil {
			a := *s.lastAction
			entry.LastAction = &a
		}
		if s.unfundedUntil != nil {
			entry.UnfundedUntil = game.Int64Ptr(game.Millis(*s.unfundedUntil))
		}
		seats[i] = entry
	}
	state := t.State()
	var sh *SnapshotHand
	if h := t.hand; h != nil {
		state = game.TableBetting
		sh = &SnapshotHand{
			ID: h.id, HandNo: h.handNo, StartedAt: game.Millis(h.startedAt), Pot: h.pot,
			Streets: append([]Street{}, h.streets...), StreetIndex: h.streetIndex,
			Deck: game.CardCodes(h.deck), Community: game.CardCodes(h.community), DealerCards: game.CardCodes(h.dealerCards),
			Button: h.button, CurrentBet: h.currentBet, MinRaise: h.minRaise, TurnSeat: h.turnSeat,
			Contributions: make([]SnapshotContribution, 0, len(h.contribOrder)),
			ActionIDs:     make([]string, 0, len(h.actionIDs)),
		}
		if !h.turnDeadline.IsZero() {
			sh.TurnDeadline = game.Int64Ptr(game.Millis(h.turnDeadline))
		}
		for _, userID := range h.contribOrder {
			c := h.contributions[userID]
			if c == nil {
				continue
			}
			sh.Contributions = append(sh.Contributions, SnapshotContribution{
				UserID: c.userID, DisplayName: c.displayName, SeatIndex: c.seatIndex, Contributed: c.contributed,
				Status: c.status, Cards: game.CardCodes(c.cards), Played: c.played, Folded: c.folded,
				LeftMidHand: c.leftMidHand, AllIn: c.allIn, Won: c.won, Chips: c.chips, ChipsWritten: c.chipsWritten,
			})
		}
		for id := range h.actionIDs {
			sh.ActionIDs = append(sh.ActionIDs, id)
		}
		sort.Strings(sh.ActionIDs)
		if h.lastDeparture != nil {
			sh.LastDeparture = game.StrPtr(*h.lastDeparture)
		}
	}
	snap := &Snapshot{
		Game: game.GamePoker, RoomID: t.id, Code: t.code, Category: t.cfg.Category, State: state,
		HandNo: t.handNo, Button: t.button, Hand: sh, Seats: seats, Seq: t.LiveSeq(), Version: t.version.Load(),
		IsPrivate: t.isPrivate, CreatedAt: game.Millis(t.createdAt), Config: snapshotConfig(t.cfg),
		LastResult: t.lastResult,
	}
	if t.startsAt != nil {
		snap.StartsAt = game.Int64Ptr(game.Millis(*t.startsAt))
	}
	return snap
}

func (t *Table) marshalSnapshot(seq int64) ([]byte, error) {
	snap := t.snapshot()
	snap.Seq = seq
	return json.Marshal(snap)
}

func snapshotConfig(cfg Config) SnapshotConfig {
	return SnapshotConfig{
		Category: cfg.Category, Variant: cfg.Variant.Variant, BootAmount: cfg.BootAmount,
		MaxPlayers: cfg.MaxPlayers, MinPlayers: cfg.MinPlayers,
		TurnTimeoutMs: cfg.TurnTimeout.Milliseconds(), NextHandDelayMs: cfg.NextHandDelay.Milliseconds(),
		UnfundedGraceMs: cfg.UnfundedGrace.Milliseconds(), MaxMissedTurns: cfg.MaxMissedTurns,
		MinBuyIn: cfg.MinBuyIn, MaxDiscards: cfg.MaxDiscards, ChatMaxHistory: cfg.ChatMaxHistory, ChatMaxLength: cfg.ChatMaxLength,
	}
}

func configFrom(c SnapshotConfig) (Config, error) {
	variant, ok := Variants[c.Variant]
	if !ok {
		if v, ok2 := VariantOf(c.Category); ok2 {
			variant = Variants[v]
		} else {
			return Config{}, fmt.Errorf("variant %q is not one this server plays", c.Variant)
		}
	}
	return Config{
		Category: variant.Variant.Category(), Variant: variant, BootAmount: c.BootAmount,
		MaxPlayers: c.MaxPlayers, MinPlayers: c.MinPlayers,
		TurnTimeout: time.Duration(c.TurnTimeoutMs) * time.Millisecond, NextHandDelay: time.Duration(c.NextHandDelayMs) * time.Millisecond,
		UnfundedGrace: time.Duration(c.UnfundedGraceMs) * time.Millisecond, MaxMissedTurns: c.MaxMissedTurns,
		MinBuyIn: c.MinBuyIn, MaxDiscards: c.MaxDiscards, ChatMaxHistory: c.ChatMaxHistory, ChatMaxLength: c.ChatMaxLength,
	}, nil
}

// ParseSnapshot decodes and validates a stored document.
func ParseSnapshot(data []byte) (*Snapshot, error) {
	snap := &Snapshot{}
	if err := json.Unmarshal(data, snap); err != nil {
		return nil, fmt.Errorf("unparseable poker snapshot: %w", err)
	}
	if err := validateSnapshot(snap); err != nil {
		return nil, err
	}
	return snap, nil
}

// validateSnapshot refuses a document a restore could not turn into a
// consistent room: references (seats, user ids, card codes), the variant,
// and a hand whose cards are not all distinct.
func validateSnapshot(snap *Snapshot) error {
	if snap == nil {
		return errors.New("nil snapshot")
	}
	if snap.Game != game.GamePoker {
		return fmt.Errorf("snapshot %s is of game %q, not poker", snap.RoomID, snap.Game)
	}
	if snap.RoomID == "" {
		return errors.New("snapshot has no roomId")
	}
	cfg := snap.Config
	if cfg.MaxPlayers <= 0 {
		return fmt.Errorf("snapshot %s has no config (maxPlayers %d)", snap.RoomID, cfg.MaxPlayers)
	}
	if cfg.BootAmount <= 0 {
		return fmt.Errorf("snapshot %s has bootAmount %d", snap.RoomID, cfg.BootAmount)
	}
	if _, ok := Variants[cfg.Variant]; !ok {
		return fmt.Errorf("snapshot %s plays %q, which this server does not", snap.RoomID, cfg.Variant)
	}
	if len(snap.Seats) > cfg.MaxPlayers {
		return fmt.Errorf("snapshot %s has %d seats for maxPlayers %d", snap.RoomID, len(snap.Seats), cfg.MaxPlayers)
	}
	switch snap.State {
	case game.TableWaiting, game.TableStarting, game.TableBetting, game.TableShowdown:
	default:
		return fmt.Errorf("snapshot %s has state %q", snap.RoomID, snap.State)
	}
	users := map[string]int{}
	inPlay := map[string]bool{}
	note := func(codes []string, what string) error {
		if err := game.ValidCardCodes(codes); err != nil {
			return fmt.Errorf("snapshot %s: %s: %w", snap.RoomID, what, err)
		}
		for _, c := range codes {
			if inPlay[c] {
				return fmt.Errorf("snapshot %s: card %s appears twice", snap.RoomID, c)
			}
			inPlay[c] = true
		}
		return nil
	}
	for index, s := range snap.Seats {
		if s == nil {
			continue
		}
		if s.SeatIndex != index {
			return fmt.Errorf("snapshot %s: seat at position %d says seatIndex %d", snap.RoomID, index, s.SeatIndex)
		}
		if s.UserID == "" {
			return fmt.Errorf("snapshot %s: seat %d has no userId", snap.RoomID, index)
		}
		if _, dup := users[s.UserID]; dup {
			return fmt.Errorf("snapshot %s: user %s holds two seats", snap.RoomID, s.UserID)
		}
		users[s.UserID] = index
		switch s.Status {
		case game.SeatWaiting, game.SeatActive, game.SeatPacked, game.SeatLost, game.SeatWon:
		default:
			return fmt.Errorf("snapshot %s: seat %d has status %q", snap.RoomID, index, s.Status)
		}
		if s.Chips < 0 {
			return fmt.Errorf("snapshot %s: seat %d has %d chips", snap.RoomID, index, s.Chips)
		}
		if err := note(s.Cards, fmt.Sprintf("seat %d", index)); err != nil {
			return err
		}
	}
	h := snap.Hand
	if h == nil {
		return nil
	}
	if h.ID == "" {
		return fmt.Errorf("snapshot %s: hand has no id", snap.RoomID)
	}
	if len(h.Streets) == 0 {
		return fmt.Errorf("snapshot %s: hand has no streets", snap.RoomID)
	}
	if h.StreetIndex < -1 || h.StreetIndex > len(h.Streets) {
		return fmt.Errorf("snapshot %s: street index %d of %d", snap.RoomID, h.StreetIndex, len(h.Streets))
	}
	seatOK := func(i int) bool { return i >= 0 && i < len(snap.Seats) && snap.Seats[i] != nil }
	if h.TurnSeat != -1 && !seatOK(h.TurnSeat) {
		return fmt.Errorf("snapshot %s: turn seat %d is empty", snap.RoomID, h.TurnSeat)
	}
	if !seatOK(h.Button) && h.Button != -1 {
		return fmt.Errorf("snapshot %s: button seat %d is empty", snap.RoomID, h.Button)
	}
	for _, what := range []struct {
		codes []string
		name  string
	}{{h.Community, "community"}, {h.DealerCards, "dealer"}, {h.Deck, "deck"}} {
		if err := note(what.codes, what.name); err != nil {
			return err
		}
	}
	for _, c := range h.Contributions {
		if c.UserID == "" {
			return fmt.Errorf("snapshot %s: a contribution has no userId", snap.RoomID)
		}
		if c.Contributed < 0 || c.Chips < 0 {
			return fmt.Errorf("snapshot %s: contribution of %s is negative", snap.RoomID, c.UserID)
		}
		if err := game.ValidCardCodes(c.Cards); err != nil {
			return fmt.Errorf("snapshot %s: contribution of %s: %w", snap.RoomID, c.UserID, err)
		}
	}
	return nil
}

// restoreTable rebuilds a room from a stored document without arming a
// clock; Resume does that once the RoomManager has registered it.
func restoreTable(snap *Snapshot, opts TableOptions) (*Table, error) {
	if err := validateSnapshot(snap); err != nil {
		return nil, fmt.Errorf("restore poker room: %w", err)
	}
	cfg, err := configFrom(snap.Config)
	if err != nil {
		return nil, fmt.Errorf("restore poker room %s: %w", snap.RoomID, err)
	}
	opts.ID = snap.RoomID
	opts.Code = snap.Code
	opts.Config = cfg
	opts.IsPrivate = snap.IsPrivate
	t := newTableCore(opts)
	t.createdAt = game.FromMillis(snap.CreatedAt)
	t.handNo = snap.HandNo
	t.button = snap.Button
	t.version.Store(snap.Version)
	t.SetSeq(snap.Seq)
	t.lastResult = snap.LastResult

	for index, ss := range snap.Seats {
		if ss == nil {
			continue
		}
		s := &seat{
			seatIndex: index, userID: ss.UserID, displayName: ss.DisplayName, chips: ss.Chips, connected: false,
			status: ss.Status, cards: game.ParseCards(ss.Cards), contributed: ss.Contributed, streetBet: ss.StreetBet,
			allIn: ss.AllIn, acted: ss.Acted, drew: ss.Drew, played: ss.Played, missedTurns: ss.MissedTurns,
			joinedAt: game.FromMillis(ss.JoinedAt), kickPending: ss.KickPending,
		}
		if ss.AvatarURL != nil {
			s.avatarURL = game.StrPtr(*ss.AvatarURL)
		}
		if ss.LastAction != nil {
			a := *ss.LastAction
			s.lastAction = &a
		}
		if ss.UnfundedUntil != nil {
			until := game.FromMillis(*ss.UnfundedUntil)
			s.unfundedUntil = &until
		}
		t.seats[index] = s
	}
	t.refreshPlayerCount()

	if sh := snap.Hand; sh != nil {
		h := &hand{
			id: sh.ID, handNo: sh.HandNo, startedAt: game.FromMillis(sh.StartedAt), pot: sh.Pot,
			streets: append([]Street{}, sh.Streets...), streetIndex: sh.StreetIndex,
			deck: game.ParseCards(sh.Deck), community: game.ParseCards(sh.Community), dealerCards: game.ParseCards(sh.DealerCards),
			button: sh.Button, currentBet: sh.CurrentBet, minRaise: sh.MinRaise, turnSeat: sh.TurnSeat,
			contributions: make(map[string]*contribution, len(sh.Contributions)),
			contribOrder:  make([]string, 0, len(sh.Contributions)),
			actionIDs:     make(map[string]struct{}, len(sh.ActionIDs)),
		}
		if h.community == nil {
			h.community = []game.Card{}
		}
		if sh.TurnDeadline != nil {
			h.turnDeadline = game.FromMillis(*sh.TurnDeadline)
		}
		for _, id := range sh.ActionIDs {
			h.actionIDs[id] = struct{}{}
		}
		for _, c := range sh.Contributions {
			h.contributions[c.UserID] = &contribution{
				userID: c.UserID, displayName: c.DisplayName, seatIndex: c.SeatIndex, contributed: c.Contributed,
				status: c.Status, cards: game.ParseCards(c.Cards), played: c.Played, folded: c.Folded,
				leftMidHand: c.LeftMidHand, allIn: c.AllIn, won: c.Won, chips: c.Chips, chipsWritten: c.ChipsWritten,
			}
			h.contribOrder = append(h.contribOrder, c.UserID)
		}
		if sh.LastDeparture != nil {
			h.lastDeparture = game.StrPtr(*sh.LastDeparture)
		}
		t.setHand(h)
		t.setState(game.TableBetting)
	} else if snap.State == game.TableStarting {
		t.setState(game.TableStarting)
		startsAt := t.clock.Now()
		if snap.StartsAt != nil {
			startsAt = game.FromMillis(*snap.StartsAt)
		}
		t.startsAt = &startsAt
	} else {
		t.setState(game.TableWaiting)
	}
	go t.Loop()
	return t, nil
}

// RestoreTable is restoreTable + Resume, for tests.
func RestoreTable(snap *Snapshot, opts TableOptions) (*Table, error) {
	t, err := restoreTable(snap, opts)
	if err != nil {
		return nil, err
	}
	if err := t.Resume(); err != nil {
		return nil, err
	}
	return t, nil
}
