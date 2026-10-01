package purchase

import (
	"crypto/ecdsa"
	"crypto/sha256"
	"crypto/x509"
	_ "embed"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"strings"
	"time"
)

// The App Store side of the store (owner, 2 Oct 2026: "i want to release app
// on apple store … Build Apple purchases now").
//
// A purchase made with StoreKit 2 reaches the app as a SIGNED TRANSACTION: a
// JWS (three base64url segments) whose header carries the certificate chain
// that signed it (`x5c`: leaf, intermediate, root) and whose payload says
// what was bought (JWSTransactionDecodedPayload). The client posts that
// string to POST /api/purchases/apple and this file answers the only
// question that matters, exactly as google.go does for Play: did this person
// really buy this product?
//
// It is answered WITHOUT calling Apple and without a secret. The chain is
// verified up to Apple Root CA - G3, which is compiled into the binary
// (apple_root_ca_g3.pem, from https://www.apple.com/certificateauthority/,
// SHA-256 63:34:3A:BF:…:3E:91:79), the two certificates under it must carry
// the marker extensions Apple issues its App Store signing certificates with,
// and the ES256 signature must be the leaf's. That is the procedure of
// Apple's own app-store-server-library (SignedDataVerifier) with its online
// revocation checks off. Nothing here can be forged by a client: a
// transaction a jailbroken phone or a local StoreKit test session signs does
// not chain to Apple's root.

//go:embed apple_root_ca_g3.pem
var appleRootCAG3 []byte

// AppleTokenPrefix marks the idempotency key of an App Store purchase. The
// credit paths are keyed on one string per purchase — Play's purchase token —
// and an App Store purchase's is "appstore:<transactionId>": in chip_ledger
// (ActionID), and as the primary key of diamond_purchases, hammer_purchases
// and badge_purchases. A Play token is a long opaque string Google mints and
// never starts with it.
const AppleTokenPrefix = "appstore:"

// AppleToken is the idempotency key of the App Store transaction with this
// id. Apple's transactionId is unique per purchase and stable across every
// delivery of it, which is what a replay guard needs.
func AppleToken(transactionID string) string { return AppleTokenPrefix + transactionID }

// The App Store environments a signed transaction names.
const (
	AppleProduction = "Production"
	AppleSandbox    = "Sandbox"
)

// Apple's marker extensions (Apple's Worldwide Developer Relations
// Certification Practice Statement): the intermediate that signs App Store
// receipts carries 1.2.840.113635.100.6.2.1 and the leaf that signs a
// transaction 1.2.840.113635.100.6.11.1. A certificate Apple issued for
// anything else — an app's own signing certificate, say — chains to the same
// root and lacks them.
var (
	oidAppleIntermediate = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 2, 1}
	oidAppleReceiptLeaf  = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 11, 1}
)

// AppleTransaction is what a verified signed transaction says.
type AppleTransaction struct {
	// TransactionID is Apple's id for this purchase — the idempotency key
	// (AppleToken) and what a support question or a payout line is traced by.
	TransactionID string
	// ProductID is the App Store Connect product bought.
	ProductID string
	// BundleID is the app the purchase was made in.
	BundleID string
	// Environment is Production or Sandbox. TestFlight builds, sandbox
	// testers and App Review all buy in Sandbox, where nothing is charged.
	Environment string
	// PurchaseTimeMillis is when the App Store took the money.
	PurchaseTimeMillis int64
	// Quantity is how many of the product one transaction bought (1 unless
	// the app asks for more, which this one never does).
	Quantity int64
}

// AppleVerifier verifies StoreKit 2 signed transactions for this app.
type AppleVerifier struct {
	// BundleIDs are the apps a transaction may have been made in
	// (APPLE_BUNDLE_IDS). A transaction for any other bundle is refused.
	BundleIDs []string
	// Environments are the App Store environments accepted
	// (APPLE_IAP_ENVIRONMENTS). Sandbox must be among them for App Review and
	// TestFlight to be able to buy: both purchase in the sandbox.
	Environments []string

	roots *x509.CertPool
	now   func() time.Time
}

// NewAppleVerifier builds the verifier. No bundle id is not an error — it
// returns nil and the caller keeps the App Store door shut (503), as a server
// with no Play credentials keeps Play's. No environment means Production and
// Sandbox both.
func NewAppleVerifier(bundleIDs, environments []string) (*AppleVerifier, error) {
	if len(bundleIDs) == 0 {
		return nil, nil
	}
	root, err := parseCertificatePEM(appleRootCAG3)
	if err != nil {
		return nil, fmt.Errorf("purchase: Apple root certificate: %w", err)
	}
	pool := x509.NewCertPool()
	pool.AddCert(root)
	if len(environments) == 0 {
		environments = []string{AppleProduction, AppleSandbox}
	}
	for _, env := range environments {
		if env != AppleProduction && env != AppleSandbox {
			return nil, fmt.Errorf("purchase: unknown App Store environment %q (want %s or %s)", env, AppleProduction, AppleSandbox)
		}
	}
	return &AppleVerifier{BundleIDs: bundleIDs, Environments: environments, roots: pool, now: time.Now}, nil
}

// WithRoots returns a copy of v that trusts roots instead of Apple's — for
// tests, which sign transactions with a root of their own.
func (v *AppleVerifier) WithRoots(roots *x509.CertPool) *AppleVerifier {
	c := *v
	c.roots = roots
	return &c
}

func parseCertificatePEM(data []byte) (*x509.Certificate, error) {
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, errors.New("no PEM block")
	}
	return x509.ParseCertificate(block.Bytes)
}

// appleTransactionPayload is the subset of JWSTransactionDecodedPayload read.
type appleTransactionPayload struct {
	TransactionID  string `json:"transactionId"`
	BundleID       string `json:"bundleId"`
	ProductID      string `json:"productId"`
	PurchaseDate   int64  `json:"purchaseDate"`
	SignedDate     int64  `json:"signedDate"`
	Quantity       int64  `json:"quantity"`
	Environment    string `json:"environment"`
	RevocationDate *int64 `json:"revocationDate"`
}

// Verify checks one signed transaction and that it is a purchase of
// productID in this app.
//
// ErrUnverified: not a JWS, not signed by Apple's App Store chain, or signed
// for another app, another product or an environment this server does not
// accept — treat as fraud, never as a transient failure. ErrNotPurchased: a
// genuine transaction Apple has since revoked (a refund). There is no
// "ours to retry" failure here, because nothing is asked of the network.
func (v *AppleVerifier) Verify(productID, signedTransaction string) (AppleTransaction, error) {
	parts := strings.Split(signedTransaction, ".")
	if len(parts) != 3 {
		return AppleTransaction{}, ErrUnverified
	}
	headerJSON, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return AppleTransaction{}, ErrUnverified
	}
	payloadJSON, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return AppleTransaction{}, ErrUnverified
	}
	signature, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil {
		return AppleTransaction{}, ErrUnverified
	}
	var header struct {
		Alg string   `json:"alg"`
		X5c []string `json:"x5c"`
	}
	if err := json.Unmarshal(headerJSON, &header); err != nil {
		return AppleTransaction{}, ErrUnverified
	}
	// ES256 and nothing else: the algorithm is never the token's to choose.
	if header.Alg != "ES256" || len(header.X5c) != 3 {
		return AppleTransaction{}, ErrUnverified
	}
	var payload appleTransactionPayload
	if err := json.Unmarshal(payloadJSON, &payload); err != nil {
		return AppleTransaction{}, ErrUnverified
	}

	chain := make([]*x509.Certificate, 0, 2)
	for _, encoded := range header.X5c[:2] {
		// x5c is standard base64 of the DER, not base64url (RFC 7515 §4.1.6).
		der, err := base64.StdEncoding.DecodeString(encoded)
		if err != nil {
			return AppleTransaction{}, ErrUnverified
		}
		cert, err := x509.ParseCertificate(der)
		if err != nil {
			return AppleTransaction{}, ErrUnverified
		}
		chain = append(chain, cert)
	}
	leaf, intermediate := chain[0], chain[1]
	if !hasExtension(leaf, oidAppleReceiptLeaf) || !hasExtension(intermediate, oidAppleIntermediate) {
		return AppleTransaction{}, ErrUnverified
	}
	// The chain is judged at the moment the transaction was signed, as
	// Apple's library does with its online checks off: a signing certificate
	// lives a couple of years and a purchase delivered late (a phone offline
	// since it bought) must still verify. The date is inside the signed
	// payload, so it is only believed once the signature below holds.
	at := v.now()
	if payload.SignedDate > 0 {
		at = time.UnixMilli(payload.SignedDate)
	}
	intermediates := x509.NewCertPool()
	intermediates.AddCert(intermediate)
	// Apple's marker extensions are ones crypto/x509 does not know; where one
	// is marked critical it would fail the chain for being unhandled, and it
	// has just been handled above.
	leaf.UnhandledCriticalExtensions = withoutAppleMarkers(leaf.UnhandledCriticalExtensions)
	intermediate.UnhandledCriticalExtensions = withoutAppleMarkers(intermediate.UnhandledCriticalExtensions)
	if _, err := leaf.Verify(x509.VerifyOptions{
		Roots:         v.roots,
		Intermediates: intermediates,
		CurrentTime:   at,
		KeyUsages:     []x509.ExtKeyUsage{x509.ExtKeyUsageAny},
	}); err != nil {
		return AppleTransaction{}, ErrUnverified
	}

	key, ok := leaf.PublicKey.(*ecdsa.PublicKey)
	if !ok || len(signature) != 64 {
		return AppleTransaction{}, ErrUnverified
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	r := new(big.Int).SetBytes(signature[:32])
	s := new(big.Int).SetBytes(signature[32:])
	if !ecdsa.Verify(key, digest[:], r, s) {
		return AppleTransaction{}, ErrUnverified
	}

	// Signed by Apple. Now: is it a purchase of THIS product in THIS app, in
	// an environment this server takes?
	if payload.TransactionID == "" || !contains(v.BundleIDs, payload.BundleID) ||
		payload.ProductID != productID || !contains(v.Environments, payload.Environment) {
		return AppleTransaction{}, ErrUnverified
	}
	if payload.RevocationDate != nil {
		return AppleTransaction{}, ErrNotPurchased
	}
	quantity := payload.Quantity
	if quantity <= 0 {
		quantity = 1
	}
	return AppleTransaction{
		TransactionID:      payload.TransactionID,
		ProductID:          payload.ProductID,
		BundleID:           payload.BundleID,
		Environment:        payload.Environment,
		PurchaseTimeMillis: payload.PurchaseDate,
		Quantity:           quantity,
	}, nil
}

func hasExtension(cert *x509.Certificate, oid asn1.ObjectIdentifier) bool {
	for _, ext := range cert.Extensions {
		if ext.Id.Equal(oid) {
			return true
		}
	}
	return false
}

func withoutAppleMarkers(oids []asn1.ObjectIdentifier) []asn1.ObjectIdentifier {
	var kept []asn1.ObjectIdentifier
	for _, oid := range oids {
		if oid.Equal(oidAppleIntermediate) || oid.Equal(oidAppleReceiptLeaf) {
			continue
		}
		kept = append(kept, oid)
	}
	return kept
}

func contains(list []string, s string) bool {
	for _, item := range list {
		if item == s {
			return true
		}
	}
	return false
}
