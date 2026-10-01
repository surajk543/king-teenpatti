// Package appletest signs App Store transactions for tests: a certificate
// chain shaped as Apple's is (root → intermediate → leaf, with Apple's marker
// extensions) under a root of the test's own, and the JWS a StoreKit 2
// purchase hands the app. purchase.AppleVerifier.WithRoots(signer.Roots)
// trusts it; nothing it signs chains to Apple's real root.
package appletest

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"testing"
	"time"
)

// Apple's marker extensions, as purchase/apple.go reads them.
var (
	OIDIntermediate = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 2, 1}
	OIDLeaf         = asn1.ObjectIdentifier{1, 2, 840, 113635, 100, 6, 11, 1}
)

// Signer holds one test chain.
type Signer struct {
	Roots *x509.CertPool

	rootDER, intermediateDER, leafDER []byte
	leafKey                           *ecdsa.PrivateKey
}

// Options shape the chain; the zero value is a chain like Apple's.
type Options struct {
	// NoLeafMarker / NoIntermediateMarker leave Apple's marker extension off
	// that certificate.
	NoLeafMarker         bool
	NoIntermediateMarker bool
	// NotAfter ends the leaf's validity (default: ten years from now).
	NotAfter time.Time
}

// New makes a root, an intermediate and a leaf.
func New(t testing.TB, opts Options) *Signer {
	t.Helper()
	now := time.Now()
	rootKey := newKey(t, elliptic.P384())
	rootTmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "Test Root CA - G3"},
		NotBefore:             now.AddDate(0, -1, 0),
		NotAfter:              now.AddDate(20, 0, 0),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign,
	}
	rootDER := create(t, rootTmpl, rootTmpl, &rootKey.PublicKey, rootKey)
	root := parse(t, rootDER)

	interKey := newKey(t, elliptic.P384())
	interTmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(2),
		Subject:               pkix.Name{CommonName: "Test Worldwide Developer Relations"},
		NotBefore:             now.AddDate(0, -1, 0),
		NotAfter:              now.AddDate(15, 0, 0),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign,
	}
	if !opts.NoIntermediateMarker {
		interTmpl.ExtraExtensions = []pkix.Extension{{Id: OIDIntermediate, Value: []byte{0x05, 0x00}}}
	}
	interDER := create(t, interTmpl, root, &interKey.PublicKey, rootKey)
	inter := parse(t, interDER)

	leafKey := newKey(t, elliptic.P256())
	notAfter := opts.NotAfter
	if notAfter.IsZero() {
		notAfter = now.AddDate(10, 0, 0)
	}
	leafTmpl := &x509.Certificate{
		SerialNumber: big.NewInt(3),
		Subject:      pkix.Name{CommonName: "Test Prod ECC Mac App Store and iTunes Store Receipt Signing"},
		NotBefore:    now.AddDate(0, -1, 0),
		NotAfter:     notAfter,
		KeyUsage:     x509.KeyUsageDigitalSignature,
	}
	if !opts.NoLeafMarker {
		leafTmpl.ExtraExtensions = []pkix.Extension{{Id: OIDLeaf, Value: []byte{0x05, 0x00}}}
	}
	leafDER := create(t, leafTmpl, inter, &leafKey.PublicKey, interKey)

	pool := x509.NewCertPool()
	pool.AddCert(root)
	return &Signer{Roots: pool, rootDER: rootDER, intermediateDER: interDER, leafDER: leafDER, leafKey: leafKey}
}

// Transaction is a signed transaction's payload, with the defaults a real
// purchase carries. Zero fields are filled by Sign.
type Transaction struct {
	TransactionID  string
	BundleID       string
	ProductID      string
	Environment    string
	Quantity       int64
	PurchaseDate   int64
	SignedDate     int64
	RevocationDate int64
}

// Sign returns the JWS of tx (StoreKit's jwsRepresentation).
func (s *Signer) Sign(t testing.TB, tx Transaction) string {
	t.Helper()
	now := time.Now().UnixMilli()
	if tx.PurchaseDate == 0 {
		tx.PurchaseDate = now
	}
	if tx.SignedDate == 0 {
		tx.SignedDate = now
	}
	if tx.Environment == "" {
		tx.Environment = "Production"
	}
	if tx.Quantity == 0 {
		tx.Quantity = 1
	}
	payload := map[string]any{
		"transactionId":         tx.TransactionID,
		"originalTransactionId": tx.TransactionID,
		"bundleId":              tx.BundleID,
		"productId":             tx.ProductID,
		"purchaseDate":          tx.PurchaseDate,
		"signedDate":            tx.SignedDate,
		"quantity":              tx.Quantity,
		"type":                  "Consumable",
		"inAppOwnershipType":    "PURCHASED",
		"environment":           tx.Environment,
	}
	if tx.RevocationDate != 0 {
		payload["revocationDate"] = tx.RevocationDate
		payload["revocationReason"] = 0
	}
	return s.SignRaw(t, "ES256", payload)
}

// SignRaw signs any payload under any `alg` header with the leaf's key.
func (s *Signer) SignRaw(t testing.TB, alg string, payload map[string]any) string {
	t.Helper()
	header, err := json.Marshal(map[string]any{
		"alg": alg,
		"x5c": []string{
			base64.StdEncoding.EncodeToString(s.leafDER),
			base64.StdEncoding.EncodeToString(s.intermediateDER),
			base64.StdEncoding.EncodeToString(s.rootDER),
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	signing := base64.RawURLEncoding.EncodeToString(header) + "." + base64.RawURLEncoding.EncodeToString(body)
	digest := sha256.Sum256([]byte(signing))
	r, sig, err := ecdsa.Sign(rand.Reader, s.leafKey, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	raw := make([]byte, 64)
	r.FillBytes(raw[:32])
	sig.FillBytes(raw[32:])
	return signing + "." + base64.RawURLEncoding.EncodeToString(raw)
}

func newKey(t testing.TB, curve elliptic.Curve) *ecdsa.PrivateKey {
	t.Helper()
	key, err := ecdsa.GenerateKey(curve, rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return key
}

func create(t testing.TB, tmpl, parent *x509.Certificate, pub *ecdsa.PublicKey, signer *ecdsa.PrivateKey) []byte {
	t.Helper()
	der, err := x509.CreateCertificate(rand.Reader, tmpl, parent, pub, signer)
	if err != nil {
		t.Fatal(err)
	}
	return der
}

func parse(t testing.TB, der []byte) *x509.Certificate {
	t.Helper()
	cert, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	return cert
}
