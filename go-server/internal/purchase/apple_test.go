package purchase_test

import (
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/purchase"
	"github.com/surajk543/king-teenpatti/go-server/internal/purchase/appletest"
)

const testBundle = "com.sungamestudio.kingteenpatti"

func appleVerifier(t *testing.T, signer *appletest.Signer, environments ...string) *purchase.AppleVerifier {
	t.Helper()
	v, err := purchase.NewAppleVerifier([]string{testBundle}, environments)
	if err != nil {
		t.Fatal(err)
	}
	return v.WithRoots(signer.Roots)
}

func TestTheCompiledInRootIsApplesRootCAG3(t *testing.T) {
	data, err := os.ReadFile("apple_root_ca_g3.pem")
	if err != nil {
		t.Fatal(err)
	}
	block, _ := pem.Decode(data)
	if block == nil {
		t.Fatal("no PEM block in apple_root_ca_g3.pem")
	}
	// The fingerprint Apple publishes for Apple Root CA - G3
	// (https://www.apple.com/certificateauthority/).
	const want = "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179"
	sum := sha256.Sum256(block.Bytes)
	if got := hex.EncodeToString(sum[:]); got != want {
		t.Fatalf("root fingerprint = %s, want %s", got, want)
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		t.Fatal(err)
	}
	if cert.Subject.CommonName != "Apple Root CA - G3" || !cert.IsCA {
		t.Fatalf("root is %q (CA %v)", cert.Subject.CommonName, cert.IsCA)
	}
}

func TestASignedTransactionOfThisProductInThisAppVerifies(t *testing.T) {
	signer := appletest.New(t, appletest.Options{})
	v := appleVerifier(t, signer)
	jws := signer.Sign(t, appletest.Transaction{
		TransactionID: "2000000123456789", BundleID: testBundle, ProductID: "chips_a_99", PurchaseDate: 1790000000000,
	})
	tx, err := v.Verify("chips_a_99", jws)
	if err != nil {
		t.Fatalf("Verify: %v", err)
	}
	if tx.TransactionID != "2000000123456789" || tx.ProductID != "chips_a_99" || tx.BundleID != testBundle ||
		tx.Environment != purchase.AppleProduction || tx.PurchaseTimeMillis != 1790000000000 || tx.Quantity != 1 {
		t.Fatalf("transaction = %+v", tx)
	}
	if got := purchase.AppleToken(tx.TransactionID); got != "appstore:2000000123456789" {
		t.Fatalf("token = %q", got)
	}
}

func TestASandboxTransactionVerifiesUnlessTheServerTakesProductionOnly(t *testing.T) {
	signer := appletest.New(t, appletest.Options{})
	jws := signer.Sign(t, appletest.Transaction{
		TransactionID: "1", BundleID: testBundle, ProductID: "chips_a_99", Environment: "Sandbox",
	})
	if tx, err := appleVerifier(t, signer).Verify("chips_a_99", jws); err != nil || tx.Environment != purchase.AppleSandbox {
		t.Fatalf("default environments: %+v, %v", tx, err)
	}
	if _, err := appleVerifier(t, signer, purchase.AppleProduction).Verify("chips_a_99", jws); !errors.Is(err, purchase.ErrUnverified) {
		t.Fatalf("production only: err = %v, want ErrUnverified", err)
	}
	// A local StoreKit test session names an environment no server takes.
	xcode := signer.Sign(t, appletest.Transaction{
		TransactionID: "2", BundleID: testBundle, ProductID: "chips_a_99", Environment: "Xcode",
	})
	if _, err := appleVerifier(t, signer).Verify("chips_a_99", xcode); !errors.Is(err, purchase.ErrUnverified) {
		t.Fatalf("Xcode environment: err = %v, want ErrUnverified", err)
	}
}

func TestATransactionNotSignedByApplesChainIsRefused(t *testing.T) {
	signer := appletest.New(t, appletest.Options{})
	other := appletest.New(t, appletest.Options{})
	tx := appletest.Transaction{TransactionID: "1", BundleID: testBundle, ProductID: "chips_a_99"}
	good := signer.Sign(t, tx)

	// The real verifier trusts Apple's root alone: a chain under any other
	// root — which is all a forger can make — is refused.
	real, err := purchase.NewAppleVerifier([]string{testBundle}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := real.Verify("chips_a_99", good); !errors.Is(err, purchase.ErrUnverified) {
		t.Fatalf("a test-root chain against Apple's root: err = %v, want ErrUnverified", err)
	}

	v := appleVerifier(t, signer)
	parts := strings.Split(good, ".")
	otherParts := strings.Split(other.Sign(t, tx), ".")
	cases := map[string]string{
		"another root's chain":                other.Sign(t, tx),
		"this chain, another key's signature": parts[0] + "." + parts[1] + "." + otherParts[2],
		"a payload changed after signing":     parts[0] + "." + strings.Split(signer.Sign(t, appletest.Transaction{TransactionID: "1", BundleID: testBundle, ProductID: "premium_4_29999"}), ".")[1] + "." + parts[2],
		"two segments":                        parts[0] + "." + parts[1],
		"not a JWS":                           "MIIT…an old base64 receipt",
		"empty":                               "",
		"alg none":                            signer.SignRaw(t, "none", map[string]any{"transactionId": "1", "bundleId": testBundle, "productId": "chips_a_99", "environment": "Production"}),
		"alg HS256":                           signer.SignRaw(t, "HS256", map[string]any{"transactionId": "1", "bundleId": testBundle, "productId": "chips_a_99", "environment": "Production"}),
	}
	for name, jws := range cases {
		product := "chips_a_99"
		if name == "a payload changed after signing" {
			product = "premium_4_29999"
		}
		if _, err := v.Verify(product, jws); !errors.Is(err, purchase.ErrUnverified) {
			t.Errorf("%s: err = %v, want ErrUnverified", name, err)
		}
	}
}

func TestAChainWithoutApplesMarkersIsRefused(t *testing.T) {
	tx := appletest.Transaction{TransactionID: "1", BundleID: testBundle, ProductID: "chips_a_99"}
	for name, opts := range map[string]appletest.Options{
		"leaf":         {NoLeafMarker: true},
		"intermediate": {NoIntermediateMarker: true},
	} {
		signer := appletest.New(t, opts)
		if _, err := appleVerifier(t, signer).Verify("chips_a_99", signer.Sign(t, tx)); !errors.Is(err, purchase.ErrUnverified) {
			t.Errorf("no marker on the %s: err = %v, want ErrUnverified", name, err)
		}
	}
}

func TestATransactionForAnotherAppOrProductIsRefused(t *testing.T) {
	signer := appletest.New(t, appletest.Options{})
	v := appleVerifier(t, signer)
	cases := map[string]appletest.Transaction{
		"another app":     {TransactionID: "1", BundleID: "com.example.other", ProductID: "chips_a_99"},
		"another product": {TransactionID: "1", BundleID: testBundle, ProductID: "chips_i_7900"},
		"no id":           {BundleID: testBundle, ProductID: "chips_a_99"},
	}
	for name, tx := range cases {
		if _, err := v.Verify("chips_a_99", signer.Sign(t, tx)); !errors.Is(err, purchase.ErrUnverified) {
			t.Errorf("%s: err = %v, want ErrUnverified", name, err)
		}
	}
}

func TestARevokedTransactionIsNotAPurchase(t *testing.T) {
	signer := appletest.New(t, appletest.Options{})
	jws := signer.Sign(t, appletest.Transaction{
		TransactionID: "1", BundleID: testBundle, ProductID: "chips_a_99", RevocationDate: time.Now().UnixMilli(),
	})
	if _, err := appleVerifier(t, signer).Verify("chips_a_99", jws); !errors.Is(err, purchase.ErrNotPurchased) {
		t.Fatalf("err = %v, want ErrNotPurchased", err)
	}
}

func TestAChainIsJudgedWhenTheTransactionWasSigned(t *testing.T) {
	// The leaf ran out yesterday. A transaction it signed last week, delivered
	// today, is still a purchase; one "signed" after the leaf ran out is not.
	signer := appletest.New(t, appletest.Options{NotAfter: time.Now().Add(-24 * time.Hour)})
	v := appleVerifier(t, signer)
	before := time.Now().Add(-25 * time.Hour).UnixMilli()
	if _, err := v.Verify("chips_a_99", signer.Sign(t, appletest.Transaction{
		TransactionID: "1", BundleID: testBundle, ProductID: "chips_a_99", SignedDate: before,
	})); err != nil {
		t.Fatalf("signed while the leaf was valid: %v", err)
	}
	if _, err := v.Verify("chips_a_99", signer.Sign(t, appletest.Transaction{
		TransactionID: "2", BundleID: testBundle, ProductID: "chips_a_99",
	})); !errors.Is(err, purchase.ErrUnverified) {
		t.Fatalf("signed after the leaf ran out: err = %v, want ErrUnverified", err)
	}
}

func TestNoBundleIDKeepsTheAppStoreShutAndABadEnvironmentIsAnError(t *testing.T) {
	if v, err := purchase.NewAppleVerifier(nil, nil); v != nil || err != nil {
		t.Fatalf("no bundle: %v, %v", v, err)
	}
	if _, err := purchase.NewAppleVerifier([]string{testBundle}, []string{"Prod"}); err == nil {
		t.Fatal("an unknown environment was accepted")
	}
}

func TestAnAppStoreKeyIsItsOwnLedgerActionAndAPlayTokenKeepsItsPrefix(t *testing.T) {
	if got := purchase.ActionID(purchase.AppleToken("2000000123")); got != "appstore:2000000123" {
		t.Fatalf("App Store action id = %q", got)
	}
	if got := purchase.ActionID("opaque.play-token"); got != "gplay:opaque.play-token" {
		t.Fatalf("Play action id = %q", got)
	}
}
