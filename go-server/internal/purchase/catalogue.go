// Package purchase turns a Google Play purchase into chips, diamonds, hammers
// or — for a premium package — chips, missiles and hammers together.
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
	// Chips is what the account is credited for a chip pack or a premium
	// package. This is the authoritative figure. Zero for a diamond or hammer
	// pack.
	//
	// A chip, diamond or hammer pack fills exactly one wallet; a premium
	// package (owner, 14 Sep 2026) fills three — Chips, Missiles and Hammers
	// together, all positive. The gateway branches on which (app: playStore).
	Chips int64
	// Diamonds is what the account is credited for a diamond pack (owner,
	// 13 Sep 2026). Zero for any other product.
	Diamonds int64
	// Hammers is what the account is credited for a hammer pack (owner,
	// 13 Sep 2026) — the currency a Force Sideshow is paid in — or, beside
	// its chips and missiles, for a premium package. Zero for any other pack.
	Hammers int64
	// Missiles is what a premium package credits beside its chips and
	// hammers (owner, 14 Sep 2026). Zero for every other product: missiles
	// are otherwise traded for diamonds (POST /api/store/missiles), never
	// sold on Play alone.
	Missiles int64
	// Rupees is the list price at launch, for logs and reconciliation only.
	Rupees int
	// Pack is the owner's letter for the shelf position (A…I, D1…, H20…,
	// P1…P6), so a support question about "pack D" is answerable.
	Pack string
}

// Premium reports whether p is a premium package: chips with missiles and
// hammers, credited together through the chip path (db.CreditPurchase).
func (p Product) Premium() bool { return p.Chips > 0 && (p.Missiles > 0 || p.Hammers > 0) }

// Catalogue is the shelf, keyed by Play product id.
//
// The chip ids follow `chips_<pack>_<rupees>`: readable in the Play Console,
// in a payout report and in a log line without a lookup table. Creating every
// product below as a managed product in the Play Console, with these exact
// ids, is a manual step — the server refuses any id it does not know.
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

	// Diamond packs (owner, 13 Sep 2026), `diamonds_<count>_<rupees>`. Diamonds
	// pay for premium pictures (users.diamond); they are credited through
	// diamond_purchases, not chip_ledger, which backs the chips invariant only.
	"diamonds_1_49":     {ID: "diamonds_1_49", Pack: "D1", Rupees: 49, Diamonds: 1},
	"diamonds_5_199":    {ID: "diamonds_5_199", Pack: "D5", Rupees: 199, Diamonds: 5},
	"diamonds_20_699":   {ID: "diamonds_20_699", Pack: "D20", Rupees: 699, Diamonds: 20},
	"diamonds_100_2999": {ID: "diamonds_100_2999", Pack: "D100", Rupees: 2999, Diamonds: 100},

	// Hammer packs (owner, 13 Sep 2026), `hammers_<count>_<rupees>`. A hammer
	// pays for one Force Sideshow (users.hammer); packs are credited through
	// hammer_purchases, never chip_ledger. Like every id here, each must exist
	// as a managed product in the Play Console.
	"hammers_20_300":   {ID: "hammers_20_300", Pack: "H20", Rupees: 300, Hammers: 20},
	"hammers_50_699":   {ID: "hammers_50_699", Pack: "H50", Rupees: 699, Hammers: 50},
	"hammers_100_1299": {ID: "hammers_100_1299", Pack: "H100", Rupees: 1299, Hammers: 100},
	"hammers_250_2999": {ID: "hammers_250_2999", Pack: "H250", Rupees: 2999, Hammers: 250},

	// Premium packages (owner, 14 Sep 2026), `premium_<n>_<rupees>`: the
	// store's "Premium Package" category in the coin section. Each credits
	// chips, missiles and hammers in ONE transaction: the chips through the
	// `purchase` chip_ledger row whose UNIQUE action_id (gplay:<token>) is the
	// replay guard for all three, and users.missile and users.hammer beside it
	// only when that row went in. 1 Crore = 1,00,00,000 chips.
	"premium_1_9999":  {ID: "premium_1_9999", Pack: "P1", Rupees: 9999, Chips: 6_500_000_000, Missiles: 1, Hammers: 10},       // 650 Cr
	"premium_2_14999": {ID: "premium_2_14999", Pack: "P2", Rupees: 14999, Chips: 10_500_000_000, Missiles: 2, Hammers: 15},    // 1,050 Cr
	"premium_3_19999": {ID: "premium_3_19999", Pack: "P3", Rupees: 19999, Chips: 15_000_000_000, Missiles: 4, Hammers: 21},    // 1,500 Cr
	"premium_4_29999": {ID: "premium_4_29999", Pack: "P4", Rupees: 29999, Chips: 25_000_000_000, Missiles: 6, Hammers: 30},    // 2,500 Cr
	"premium_5_49999": {ID: "premium_5_49999", Pack: "P5", Rupees: 49999, Chips: 47_500_000_000, Missiles: 11, Hammers: 45},   // 4,750 Cr
	"premium_6_99999": {ID: "premium_6_99999", Pack: "P6", Rupees: 99999, Chips: 105_000_000_000, Missiles: 50, Hammers: 100}, // 10,500 Cr
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
