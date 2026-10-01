package auth

import (
	"context"
	"net/http"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/db"
)

// MaxSignedAssets is the most URLs one POST /api/assets/sign may ask for. The
// whole catalogue is about 130 files; the app asks for at most 100 at a time.
const MaxSignedAssets = 200

// AssetSigner hands a phone the catalogue's art (owner, 1 Oct 2026): which of
// the URLs it asks for some catalogue row stores, and each such location
// signed. app.go wires db.Assets and assets.Signer behind it.
type AssetSigner interface {
	// Stored is the subset of urls some catalogue row names (db.Assets.Stored).
	Stored(ctx context.Context, urls []string) (map[string]bool, error)
	// SignAll signs every location of the bucket in urls, on one reading of
	// the clock, and says when they stop working (assets.Signer.SignAll).
	SignAll(urls []string) (map[string]string, time.Time)
}

// SignAssetsRequest is POST /api/assets/sign's body: the asset URLs the phone
// needs to download, exactly as the routes handed them out.
type SignAssetsRequest struct {
	URLs []string `json:"urls"`
}

// SignAssetsResponse is its answer: each URL asked for that the server signs,
// mapped to its signed URL, and when every one of them stops working (epoch
// ms). Never null.
type SignAssetsResponse struct {
	URLs      map[string]string `json:"urls"`
	ExpiresAt int64             `json:"expiresAt"`
}

// SignAssets is POST /api/assets/sign {urls} (owner, 1 Oct 2026: "backend
// will give signed urls valid for 10 min, UI will download and save in phone
// disk or cache, when user login again, it will see the path of assets is
// changed, so the UI will ask for new signed url for changed asset path stored
// in db").
//
// The catalogue's art is in a private Cloudflare R2 bucket and every route
// hands out its LOCATION — the R2 URL the database stores, the stable name the
// app keys its picture cache by — which no phone can open. A phone that needs
// a file it does not have yet sends its location here and gets it back signed
// (internal/assets), valid for ten minutes: long enough to download it once.
// A file replaced in the bucket gets a new key, so the catalogue names a new
// location, which the phone sees it has not downloaded.
//
// Signed in (RequireAuth: the app version gate and a live session). Only a
// location some catalogue row stores is signed (AssetSigner.Stored) — never an
// arbitrary object of the bucket — and anything else asked for is left out of
// the answer, which the app draws as it draws a picture that failed to load.
// More than MaxSignedAssets URLs → 400 too_many_assets; a server with no R2
// keys (development) → 503 assets_unavailable.
func (h *Handler) SignAssets(w http.ResponseWriter, r *http.Request, user *db.User) {
	if h.deps.Assets == nil {
		WriteJSON(w, http.StatusServiceUnavailable, ErrorResponse{Error: CodeAssetsUnavailable, Message: MsgAssetsUnavailable})
		return
	}
	var req SignAssetsRequest
	if err := ReadJSONBody(r, &req); err != nil {
		h.writeError(w, r, err)
		return
	}
	if len(req.URLs) > MaxSignedAssets {
		WriteJSON(w, http.StatusBadRequest, ErrorResponse{Error: CodeTooManyAssets, Message: MsgTooManyAssets})
		return
	}
	asked := make([]string, 0, len(req.URLs))
	seen := make(map[string]bool, len(req.URLs))
	for _, u := range req.URLs {
		if u != "" && !seen[u] {
			seen[u] = true
			asked = append(asked, u)
		}
	}
	stored, err := h.deps.Assets.Stored(r.Context(), asked)
	if err != nil {
		h.writeError(w, r, err)
		return
	}
	known := make([]string, 0, len(stored))
	for _, u := range asked {
		if stored[u] {
			known = append(known, u)
		}
	}
	signed, expiresAt := h.deps.Assets.SignAll(known)
	WriteJSON(w, http.StatusOK, SignAssetsResponse{URLs: signed, ExpiresAt: expiresAt.UnixMilli()})
}
