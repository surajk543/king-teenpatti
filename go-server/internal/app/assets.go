package app

import (
	"github.com/surajk543/king-teenpatti/go-server/internal/assets"
	"github.com/surajk543/king-teenpatti/go-server/internal/db"
)

// assetSigning is auth.AssetSigner: the catalogue says which locations it
// stores (db.Assets.Stored), the bucket's signer signs them
// (assets.Signer.SignAll).
type assetSigning struct {
	*db.Assets
	*assets.Signer
}
