package auth

import (
	"context"
	"errors"
	"fmt"
	"net/http"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
)

// The card backs (owner, 3 Oct 2026: "Add a table cards_background which
// users can buy just like user can buy profile_pictures … add one more tab
// Cards in Store which user can buy … keep the price of all cards 5 Hammers
// validity 10 days"): the table pictures' three routes again, for the back of
// a player's cards — the catalogue, the choice and the till — with the
// profile picture's visibility: a seated player's card back goes onto their
// seat (Deps.CardBackgroundChosen), and everybody at the table sees it on that
// player's face-down cards.

// cardBackgroundLapsed tells the table a seated player's lapsed card back has
// come off (Deps.CardBackgroundChosen with nil → RoomManager
// .SetPlayerCardBackground → Table.SetCardBackground), so every viewer sees
// the default back on that player's cards the moment the sweep finds the
// rental over — tablePictureLapsed's twin. The table has normally done so
// already, by itself, at the rental's ExpiresAt (the seat's copy carries it;
// owner, 3 Oct 2026: "when validity of premium card expires, it restores
// default card"); this is for a seat whose copy says otherwise — one restored
// from a snapshot written before card backs carried their expiry, or a rental
// ended early by hand. For a player in the lobby the hook does nothing, and
// their next seat reads the account, which no longer carries it
// (db.userFromAt).
func (h *Handler) cardBackgroundLapsed(userID string) {
	if h.deps.CardBackgroundChosen != nil {
		h.deps.CardBackgroundChosen(userID, nil)
	}
}

// sweepCardBackground takes off the player's chosen card back when its rental
// has run out (db.CardBackgrounds.ExpireLapsed) and tells their seat, and
// reports whether it had to. A failure is logged and swallowed: every read of
// the account tests the expiry itself, so a tidy-up is not worth refusing
// anybody anything over.
func (h *Handler) sweepCardBackground(ctx context.Context, userID string) bool {
	if h.deps.CardBackgrounds == nil {
		return false
	}
	expired, err := h.deps.CardBackgrounds.ExpireLapsed(ctx, userID)
	if err != nil {
		if h.deps.Logger != nil {
			h.deps.Logger.Warn("card back expiry sweep failed", "userId", userID, "error", err.Error())
		}
		return false
	}
	if expired {
		if h.deps.Logger != nil {
			h.deps.Logger.Info("premium card back expired", "userId", userID)
		}
		h.cardBackgroundLapsed(userID)
	}
	return expired
}

// CardBackgrounds is GET /api/card-backgrounds (owner, 3 Oct 2026; Go only):
// the card-back catalogue in display order, as TablePictures is the cloths'.
// The token is optional for the same reasons — the catalogue is not private,
// and a token buys the `owned` flag per row; a bad one is ignored, not
// refused — and the route is never version-gated (it is not behind
// RequireAuth). Listing is also where a lapsed rental on the chosen card back
// is noticed for a player who never passes through login, and the seat told.
// An unlisted card back (is_listed = FALSE) is listed to nobody but a player
// who has it, owned and running or chosen (db.CardBackgrounds.List).
// {"cardBackgrounds": []} when nothing is on offer. The default back is no
// row of it: the app draws it as the shelf's first tile.
func (h *Handler) CardBackgrounds(w http.ResponseWriter, r *http.Request) {
	if h.deps.CardBackgrounds == nil {
		WriteJSON(w, http.StatusOK, CardBackgroundsResponse{CardBackgrounds: []db.CardBackground{}})
		return
	}
	viewer := ""
	if claims, err := h.deps.Tokens.Verify(TokenFromRequest(r)); err == nil {
		viewer = claims.Subject
	}
	if viewer != "" {
		h.sweepCardBackground(r.Context(), viewer)
	}
	backs, err := h.deps.CardBackgrounds.List(r.Context(), viewer)
	if err != nil {
		h.writeError(w, r, err)
		return
	}
	WriteJSON(w, http.StatusOK, CardBackgroundsResponse{CardBackgrounds: backs})
}

// UseCardBackground is POST /api/card-backgrounds/use {cardBackgroundId: <id>
// | null} (owner, 3 Oct 2026; Go only): UseTablePicture for the cards. Order:
// null/absent takes the card back off (the default back); an id that is not a
// positive integer or not in the catalogue → 400 unknown_card_background; a
// retired one → 400 picture_retired; a premium one the player has not bought,
// or whose rental has run out → 403 picture_locked; then CardBackgrounds.Use
// → 200 {user}, whose cardBackground is what their cards now wear.
//
// Allowed while seated: a card back moves no wallet, and everybody at the
// table sees each player's (owner, 3 Oct 2026), so the change goes straight
// onto the player's seat (Deps.CardBackgroundChosen) — mid-hand too, which
// changes nothing about the hand.
func (h *Handler) UseCardBackground(w http.ResponseWriter, r *http.Request, user *db.User) {
	var req CardBackgroundRequest
	if err := ReadJSONBody(r, &req); err != nil {
		h.writeError(w, r, err)
		return
	}

	var choice *int64
	if req.CardBackgroundID != nil {
		id, ok := pictureIDFrom(*req.CardBackgroundID)
		if !ok || h.deps.CardBackgrounds == nil {
			WriteJSON(w, http.StatusBadRequest, ErrorResponse{Error: CodeUnknownCardBackground, Message: MsgUnknownCardBackground})
			return
		}
		back, active, err := h.deps.CardBackgrounds.Find(r.Context(), user.ID, id)
		switch {
		case errors.Is(err, db.ErrCardBackgroundUnknown):
			WriteJSON(w, http.StatusBadRequest, ErrorResponse{Error: CodeUnknownCardBackground, Message: MsgUnknownCardBackground})
			return
		case err != nil:
			h.writeError(w, r, err)
			return
		case !active:
			WriteJSON(w, http.StatusBadRequest, ErrorResponse{Error: CodePictureRetired, Message: MsgCardBackgroundRetired})
			return
		case !back.Owned:
			WriteJSON(w, http.StatusForbidden, ErrorResponse{Error: CodePictureLocked, Message: MsgCardBackgroundLocked})
			return
		}
		choice = &id
	}
	if h.deps.CardBackgrounds == nil {
		// Nothing chosen and no catalogue: the default back is what the
		// account already wears.
		WriteJSON(w, http.StatusOK, UserResponse{User: user})
		return
	}

	updated, err := h.deps.CardBackgrounds.Use(r.Context(), user.ID, choice)
	if err != nil {
		h.writeError(w, r, err)
		return
	}
	if updated == nil {
		// The account went (deleted) between the token's check and the
		// choice: there is nobody left to dress.
		h.writeError(w, r, NewAuthError(CodeUnknownUser, MsgUnknownUser, 0))
		return
	}
	if h.deps.CardBackgroundChosen != nil {
		h.deps.CardBackgroundChosen(user.ID, updated.CardBackground)
	}
	WriteJSON(w, http.StatusOK, UserResponse{User: updated})
}

// BuyCardBackground is POST /api/card-backgrounds/buy {cardBackgroundId}
// (owner, 3 Oct 2026; Go only): BuyTablePicture for a card back, with the same
// rules and the same codes. The answer is {user, cardBackground, charged,
// spent}, spent in the card back's currency; every shortage is 409
// picture_chips with the wallet that was short named in the message ("You
// need 5 hammers to unlock this card back."). A seated player buys a DIAMOND
// or HAMMER card back — every seeded one is priced in hammers, five or a
// Flower back's two — and is refused a COIN one (409 seated), the money rule
// BuyPicture explains; in the lobby the purchase runs under the player's seat
// lock (Deps.WhileUnseated) for the reason given there. Buying does not put it
// on: that is /api/card-backgrounds/use. An unlisted card back (is_listed =
// FALSE) is not for sale: 400 picture_retired, unless it is already theirs
// (200 charged:false).
func (h *Handler) BuyCardBackground(w http.ResponseWriter, r *http.Request, user *db.User) {
	var req CardBackgroundRequest
	if err := ReadJSONBody(r, &req); err != nil {
		h.writeError(w, r, err)
		return
	}
	if req.CardBackgroundID == nil || h.deps.CardBackgrounds == nil {
		WriteJSON(w, http.StatusBadRequest, ErrorResponse{Error: CodeUnknownCardBackground, Message: MsgUnknownCardBackground})
		return
	}
	id, ok := pictureIDFrom(*req.CardBackgroundID)
	if !ok {
		WriteJSON(w, http.StatusBadRequest, ErrorResponse{Error: CodeUnknownCardBackground, Message: MsgUnknownCardBackground})
		return
	}

	var bought *db.CardBackgroundPurchase
	var err error
	if !h.whileUnseated(r.Context(), user.ID, func(ctx context.Context) { bought, err = h.deps.CardBackgrounds.Buy(ctx, user.ID, id) }) {
		bought, err = h.deps.CardBackgrounds.BuyAtTable(r.Context(), user.ID, id)
	}
	switch {
	case errors.Is(err, db.ErrPictureAtTable):
		WriteJSON(w, http.StatusConflict, ErrorResponse{Error: CodeSeated, Message: MsgSeatedCardBackground})
		return
	case errors.Is(err, db.ErrCardBackgroundUnknown):
		WriteJSON(w, http.StatusBadRequest, ErrorResponse{Error: CodeUnknownCardBackground, Message: MsgUnknownCardBackground})
		return
	case errors.Is(err, db.ErrPictureInactive), errors.Is(err, db.ErrPictureUnlisted):
		// Retired or off the shelf: "no longer available" either way, as
		// BuyPicture answers.
		WriteJSON(w, http.StatusBadRequest, ErrorResponse{Error: CodePictureRetired, Message: MsgCardBackgroundRetired})
		return
	case errors.Is(err, db.ErrPictureFree):
		WriteJSON(w, http.StatusBadRequest, ErrorResponse{Error: CodePictureFree, Message: MsgCardBackgroundFree})
		return
	case errors.Is(err, db.ErrPictureChips):
		WriteJSON(w, http.StatusConflict, ErrorResponse{Error: CodePictureChips, Message: MsgCardBackgroundChips})
		return
	case errors.Is(err, db.ErrPictureDiamonds):
		WriteJSON(w, http.StatusConflict, ErrorResponse{Error: CodePictureChips, Message: MsgCardBackgroundDiamonds})
		return
	case errors.Is(err, db.ErrPictureHammers):
		WriteJSON(w, http.StatusConflict, ErrorResponse{Error: CodePictureChips, Message: cardBackgroundHammersRefusal(err)})
		return
	case err != nil:
		h.writeError(w, r, err)
		return
	}

	if bought.Charged && h.deps.Logger != nil {
		h.deps.Logger.Info("card back bought",
			"userId", user.ID, "cardBackgroundId", id, "currency", bought.CardBackground.Currency, "spent", bought.Spent)
	}
	WriteJSON(w, http.StatusOK, BuyCardBackgroundResponse{
		User:           bought.User,
		CardBackground: bought.CardBackground,
		Charged:        bought.Charged,
		Spent:          bought.Spent,
	})
}

// CardBackgroundHammersMessage is PictureHammersMessage for a card back: "You
// need 5 hammers to unlock this card back.", or the singular for a price of
// one.
func CardBackgroundHammersMessage(cost int64) string {
	if cost == 1 {
		return MsgCardBackgroundHammer
	}
	return fmt.Sprintf(MsgCardBackgroundHammersFmt, cost)
}

// cardBackgroundHammersRefusal reads the price off a db.PictureHammerShortage,
// and falls back to a message without one for a refusal that carries none.
func cardBackgroundHammersRefusal(err error) string {
	var short *db.PictureHammerShortage
	if errors.As(err, &short) && short.Cost > 0 {
		return CardBackgroundHammersMessage(short.Cost)
	}
	return MsgCardBackgroundHammers
}
