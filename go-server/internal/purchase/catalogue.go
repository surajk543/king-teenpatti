// Package purchase turns a Google Play purchase into chips.
//
// Two rules shape everything here.
//
// FIRST: the server decides what a product is worth. The catalogue below is
// the only place a product id maps to a number of chips, and the client is
// never asked. A request that says "I bought 500 Crore" is answered with the
// chips its product id is worth in this file, or refused. Trusting a
// client-supplied amount would let anyone mint chips with a text editor.
//
// SECOND: a receipt is only a receipt once Google says so. The purchase token
// the client hands over is verified against the Play Developer API before a
// single chip moves (google.go). The token is also the idempotency key, so a
// replayed receipt credits nothing the second time.
package purchase

import "fmt"

// Product is one entry on the shelf, as the server understands it.
//
// The rupee price is recorded for the log and for reconciliation against a
// Play payout report; it is NOT used to decide anything. Play holds the real
// price and the currency, which vary by country, and the server never sees the
// money — only that a purchase for this product completed.
type Product struct {
	// ID is the Play Console product id. It must match exactly.
	ID string
	// Chips is what the account is credited. This is the authoritative figure.
	Chips int64
	// Rupees is the list price at launch, for logs and reconciliation only.
	Rupees int
	// Pack is the owner's letter for the shelf position (A…I), so a support
	// question about "pack D" is answerable.
	Pack string
}

// Catalogue is the shelf, keyed by Play product id.
//
// The ids follow `chips_<pack>_<rupees>`: readable in the Play Console, in a
// payout report and in a log line without a lookup table. Creating these nine
// managed products in the Play Console, with these exact ids, is a manual step
// — the server refuses any id it does not know.
var Catalogue = map[string]Product{
	"chips_a_99":   {ID: "chips_a_99", Pack: "A", Rupees: 99, Chips: 19_200_000},
	"chips_b_199":  {ID: "chips_b_199", Pack: "B", Rupees: 199, Chips: 52_800_000},
	"chips_c_399":  {ID: "chips_c_399", Pack: "C", Rupees: 399, Chips: 120_000_000},
	"chips_d_999":  {ID: "chips_d_999", Pack: "D", Rupees: 999, Chips: 352_000_000},
	"chips_e_1499": {ID: "chips_e_1499", Pack: "E", Rupees: 1499, Chips: 600_000_000},
	"chips_f_2999": {ID: "chips_f_2999", Pack: "F", Rupees: 2999, Chips: 1_500_000_000},
	"chips_g_4999": {ID: "chips_g_4999", Pack: "G", Rupees: 4999, Chips: 2_750_000_000},
	"chips_h_6900": {ID: "chips_h_6900", Pack: "H", Rupees: 6900, Chips: 4_000_000_000},
	"chips_i_7900": {ID: "chips_i_7900", Pack: "I", Rupees: 7900, Chips: 5_000_000_000},
}

// Lookup returns the product for a Play product id.
//
// An unknown id is an error, never a default: a typo in the Play Console, or a
// forged request, must not quietly credit some fallback amount.
func Lookup(productID string) (Product, error) {
	p, ok := Catalogue[productID]
	if !ok {
		return Product{}, fmt.Errorf("purchase: unknown product %q", productID)
	}
	return p, nil
}

// ActionID is the chip_ledger.action_id for a purchase: "gplay:<token>".
//
// The purchase token is unique per purchase and stable across retries, which
// is exactly what the UNIQUE index needs. It is namespaced so it can never
// collide with a hand's ids ("<handId>:settle:<userId>" and friends).
func ActionID(purchaseToken string) string { return "gplay:" + purchaseToken }
