package sim

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/surajk543/king-teenpatti/bot-play/internal/protocol"
)

// account is a guest account, kept in memory for the life of the simulation.
// Its chips are the wallet and, while it is seated, the seat's stack too.
type account struct {
	id, device, name, token string
	chips                   int64
	picture                 *int64
	sess                    *session // the live connection, if any
	seat                    *seat    // where it sits, if anywhere
	conns                   int
	resume                  *resumeOffer
}

// resumeOffer is a seat lost to the reconnect grace (or an idle kick while
// disconnected), offered back once in session:ready.resume.
type resumeOffer struct {
	t  *table
	at time.Time
}

type api struct{ s *Server }

// API is the simulated REST side.
func (s *Server) API() protocol.API { return api{s} }

// Login signs a guest device in (POST /api/auth/login): the same device is
// always the same account, whose id and token are hashes of the seed, and
// whose display name is the one given at its first login.
func (a api) Login(ctx context.Context, deviceID, displayName string) (protocol.LoginResult, error) {
	return call(ctx, a.s, func() (protocol.LoginResult, error) {
		s := a.s
		device := strings.TrimSpace(deviceID)
		if len(device) < 8 {
			return protocol.LoginResult{}, &protocol.APIError{Status: http.StatusBadRequest, Code: "invalid_device_id", Message: "A device id is at least 8 characters"}
		}
		acct, isNew := s.byDevice[device], false
		if acct == nil {
			isNew = true
			id := s.uuid("account", device)
			sum := sha256.Sum256(append(s.digest("token", id), device...))
			acct = &account{id: id, device: device, name: cleanName(displayName), chips: s.cfg.WelcomeChips,
				token: "sim." + hex.EncodeToString(sum[:16])}
			if acct.name == "" {
				acct.name = "Guest" + strings.ToUpper(strings.ReplaceAll(id, "-", "")[:5])
			}
			s.accounts[id], s.byDevice[device], s.byToken[acct.token] = acct, acct, acct
			s.stats.Minted += s.cfg.WelcomeChips
			s.log.Debug("account created", "userId", id, "name", acct.name)
		}
		return protocol.LoginResult{Token: acct.token, User: s.userOf(acct), IsNew: isNew, WelcomeChips: s.cfg.WelcomeChips}, nil
	})
}

// Tables is GET /api/tables.
func (a api) Tables(ctx context.Context) (protocol.Catalogue, error) {
	if err := ctx.Err(); err != nil {
		return protocol.Catalogue{}, err
	}
	return protocol.Catalogue{Version: a.s.version, TurnTimeoutMs: a.s.cfg.TurnTimeout.Milliseconds(),
		MaxPlayers: a.s.cfg.MaxPlayers, Tables: append([]protocol.TableEntry(nil), a.s.menu...)}, nil
}

// Me is GET /api/auth/me.
func (a api) Me(ctx context.Context, token string) (protocol.User, error) {
	return call(ctx, a.s, func() (protocol.User, error) {
		acct, err := a.s.bearer(token)
		if err != nil {
			return protocol.User{}, err
		}
		return a.s.userOf(acct), nil
	})
}

// FreePictureIDs lists the free profile pictures.
func (a api) FreePictureIDs(ctx context.Context) ([]int64, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return []int64{1, 2}, nil
}

// WearPicture records the picture on the account; it changes nothing else.
func (a api) WearPicture(ctx context.Context, token string, pictureID int64) error {
	_, err := call(ctx, a.s, func() (struct{}, error) {
		acct, err := a.s.bearer(token)
		if err == nil {
			acct.picture = ptr(pictureID)
		}
		return struct{}{}, err
	})
	return err
}

func (s *Server) bearer(token string) (*account, error) {
	if acct := s.byToken[token]; acct != nil {
		return acct, nil
	}
	return nil, &protocol.APIError{Status: http.StatusUnauthorized, Code: protocol.CodeUnknownUser, Message: "Unknown account"}
}

func (s *Server) userOf(a *account) protocol.User {
	return protocol.User{ID: a.id, DisplayName: a.name, Chips: a.chips, ActivePictureID: a.picture}
}

// cleanName keeps letters, marks, digits and spaces, up to the name limit.
func cleanName(name string) string {
	var b strings.Builder
	for _, r := range strings.TrimSpace(name) {
		if unicode.IsLetter(r) || unicode.IsNumber(r) || unicode.IsMark(r) || r == ' ' {
			b.WriteRune(r)
		}
	}
	out := []rune(strings.TrimSpace(b.String()))
	return string(out[:min(len(out), nameMaxLength)])
}

// ---- the menu ----

// rules are what a table plays by (config.TableRules at the defaults).
type rules struct {
	maxRaiseSteps, maxBetRounds, maxBlindMoves int
	potLimitMul, maxPot                        int64
	hidesChips                                 bool
}

// rulesFor is config.TableRules at the defaults for a public table: a seen
// table's two rungs, seven rounds and a per-bet ceiling of 1024 boots; a blind
// table's ladder to the stack with no round cap and no per-bet ceiling; and a
// variation table's the same as a blind one's (owner, 28 Sep 2026: "no limit
// on chaal if a player has money" — it took the seen table's until then). The
// pot cap is the menu entry's.
func rulesFor(e protocol.TableEntry) rules {
	r := rules{maxRaiseSteps: 2, maxBetRounds: 7, potLimitMul: 1024} // seen
	if e.Category == protocol.CategoryBlind || e.Category == protocol.CategoryVariation {
		r = rules{} // unlimited ladder, no round cap, no per-bet ceiling
	}
	r.hidesChips = e.Category != protocol.CategorySeen
	r.maxPot, r.maxBlindMoves = e.MaxPot, e.MaxBlindMoves
	return r
}

// defaultMenu mirrors the real default menu's Teen Patti tables the fleet
// joins, with their stack bands (CLAUDE.md §7.4 LOBBY_TABLES).
func defaultMenu() []protocol.TableEntry {
	return []protocol.TableEntry{
		{Category: protocol.CategorySeen, BootAmount: 200, MaxPot: 2_000_000, MaxBlindMoves: 4},
		{Category: protocol.CategoryBlind, BootAmount: 200, MaxChips: 2_000_000, MaxBlindMoves: 4},
		{Category: protocol.CategoryBlind, BootAmount: 5000, MaxChips: 200_000_000, MaxBlindMoves: 4},
		{Category: protocol.CategoryVariation, BootAmount: 50_000, MaxChips: 2_000_000_000, MaxBlindMoves: 4},
	}
}

// buildMenu fills in every entry's key, engine, order and clock, keeps the
// Teen Patti ones, and hashes the result into the catalogue's version. An
// entry's figures are taken as given: maxPot and maxBlindMoves 0 mean none.
func buildMenu(cfg Config) ([]protocol.TableEntry, string) {
	in := cfg.Tables
	if in == nil {
		in = defaultMenu()
	}
	var out []protocol.TableEntry
	for _, e := range in {
		if e.Engine == "" {
			e.Engine = protocol.EngineTeenPatti
		}
		known := e.Category == protocol.CategorySeen || e.Category == protocol.CategoryBlind || e.Category == protocol.CategoryVariation
		if e.Engine != protocol.EngineTeenPatti || !known || e.BootAmount <= 0 || e.IsPrivate {
			continue
		}
		e.Key = e.Category + ":" + strconv.FormatInt(e.BootAmount, 10)
		if e.SortOrder == 0 {
			e.SortOrder = (len(out) + 1) * 10
		}
		if e.TurnTimeoutMs <= 0 {
			e.TurnTimeoutMs = cfg.TurnTimeout.Milliseconds()
		}
		e.WinnerTax = false
		out = append(out, e)
	}
	body, _ := json.Marshal(out)
	sum := sha256.Sum256(body)
	return out, hex.EncodeToString(sum[:])
}

func (s *Server) entryFor(category string, boot int64) (protocol.TableEntry, bool) {
	for _, e := range s.menu {
		if e.Category == category && e.BootAmount == boot {
			return e, true
		}
	}
	return protocol.TableEntry{}, false
}

// stakes are the menu's boots, each once, in menu order (TABLE_STAKES).
func (s *Server) stakes() []int64 {
	out := []int64{}
	for _, e := range s.menu {
		if !slices.Contains(out, e.BootAmount) {
			out = append(out, e.BootAmount)
		}
	}
	return out
}
