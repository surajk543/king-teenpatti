package purchase

import (
	"context"
	"crypto/rsa"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// Errors a caller distinguishes. Everything else is a transport or
// configuration failure and should be retried or fixed, not shown to a player.
var (
	// ErrNotPurchased is Google answering that this token is not a completed
	// purchase — pending, cancelled, or refunded.
	ErrNotPurchased = errors.New("purchase: not in the purchased state")
	// ErrUnverified is Google rejecting the token outright: wrong package,
	// wrong product, or a token that never existed. Treat as fraud, not as a
	// transient failure.
	ErrUnverified = errors.New("purchase: token rejected by Google Play")
	// ErrNotConfigured is the server having no credentials. The endpoint
	// refuses rather than crediting on trust.
	ErrNotConfigured = errors.New("purchase: Google Play credentials are not configured")
)

// Verifier answers the only question that matters: did this person really buy
// this product? Implementations must fail closed.
type Verifier interface {
	Verify(ctx context.Context, productID, purchaseToken string) (Receipt, error)
}

// Receipt is what Google confirms about a completed purchase.
type Receipt struct {
	// OrderID is Play's own id for the transaction ("GPA.1234-…"), recorded so
	// a support question or a payout line can be traced to a ledger row.
	OrderID string
	// PurchaseTimeMillis is when Play took the money.
	PurchaseTimeMillis int64
	// Acknowledged reports whether this purchase has already been
	// acknowledged. Google voids an unacknowledged purchase after three days
	// and refunds the player, so this must end up true.
	Acknowledged bool
}

// serviceAccount is the subset of a Play service-account JSON key we need.
type serviceAccount struct {
	ClientEmail string `json:"client_email"`
	PrivateKey  string `json:"private_key"`
	TokenURI    string `json:"token_uri"`
}

// GoogleVerifier calls the Play Developer API.
//
// It signs a service-account assertion itself rather than pulling in the
// Google API client libraries: the whole exchange is one RS256 JWT and one
// form POST, and this repository already depends on a JWT library. Access
// tokens are cached until shortly before they expire, so a busy minute of
// purchases makes one token request, not one per purchase.
type GoogleVerifier struct {
	PackageName string
	HTTP        *http.Client

	account serviceAccount
	key     *rsa.PrivateKey

	mu       sync.Mutex
	token    string
	tokenExp time.Time
}

// NewGoogleVerifier parses a service-account JSON key.
//
// credentialsJSON is the file Google Cloud hands you for a service account
// that has been granted access in the Play Console. An empty string is not an
// error here — Open returns nil and the caller decides — but a malformed key
// is, because a server that starts with broken payment credentials will fail
// only when a player has already been charged.
func NewGoogleVerifier(packageName, credentialsJSON string) (*GoogleVerifier, error) {
	if strings.TrimSpace(credentialsJSON) == "" {
		return nil, nil
	}
	if packageName == "" {
		return nil, errors.New("purchase: GOOGLE_PLAY_PACKAGE is required alongside credentials")
	}
	var acct serviceAccount
	if err := json.Unmarshal([]byte(credentialsJSON), &acct); err != nil {
		return nil, fmt.Errorf("purchase: service account JSON: %w", err)
	}
	if acct.ClientEmail == "" || acct.PrivateKey == "" {
		return nil, errors.New("purchase: service account JSON lacks client_email or private_key")
	}
	key, err := jwt.ParseRSAPrivateKeyFromPEM([]byte(acct.PrivateKey))
	if err != nil {
		return nil, fmt.Errorf("purchase: service account private key: %w", err)
	}
	if acct.TokenURI == "" {
		acct.TokenURI = "https://oauth2.googleapis.com/token"
	}
	return &GoogleVerifier{
		PackageName: packageName,
		HTTP:        &http.Client{Timeout: 12 * time.Second},
		account:     acct,
		key:         key,
	}, nil
}

// accessToken returns a cached token, minting one when it is missing or close
// to expiry.
func (g *GoogleVerifier) accessToken(ctx context.Context) (string, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.token != "" && time.Now().Before(g.tokenExp.Add(-60*time.Second)) {
		return g.token, nil
	}

	now := time.Now()
	claims := jwt.MapClaims{
		"iss":   g.account.ClientEmail,
		"scope": "https://www.googleapis.com/auth/androidpublisher",
		"aud":   g.account.TokenURI,
		"iat":   now.Unix(),
		"exp":   now.Add(time.Hour).Unix(),
	}
	assertion, err := jwt.NewWithClaims(jwt.SigningMethodRS256, claims).SignedString(g.key)
	if err != nil {
		return "", fmt.Errorf("purchase: signing assertion: %w", err)
	}

	form := url.Values{
		"grant_type": {"urn:ietf:params:oauth:grant-type:jwt-bearer"},
		"assertion":  {assertion},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, g.account.TokenURI,
		strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	res, err := g.HTTP.Do(req)
	if err != nil {
		return "", fmt.Errorf("purchase: token request: %w", err)
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(res.Body, 1<<16))
	if res.StatusCode != http.StatusOK {
		return "", fmt.Errorf("purchase: token endpoint %d: %s", res.StatusCode, string(body))
	}
	var out struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int64  `json:"expires_in"`
	}
	if err := json.Unmarshal(body, &out); err != nil || out.AccessToken == "" {
		return "", errors.New("purchase: token endpoint returned no access_token")
	}
	g.token = out.AccessToken
	g.tokenExp = now.Add(time.Duration(out.ExpiresIn) * time.Second)
	return g.token, nil
}

// Verify asks Google about one purchase token.
//
// GET .../applications/{package}/purchases/products/{productId}/tokens/{token}
//
// A 404 or 400 means the token is not a purchase of this product in this
// package — forged, or from another app — and comes back as ErrUnverified.
// purchaseState 0 is "purchased"; 1 is cancelled and 2 is pending, and neither
// earns chips.
func (g *GoogleVerifier) Verify(ctx context.Context, productID, purchaseToken string) (Receipt, error) {
	token, err := g.accessToken(ctx)
	if err != nil {
		return Receipt{}, err
	}
	endpoint := fmt.Sprintf(
		"https://androidpublisher.googleapis.com/androidpublisher/v3/applications/%s/purchases/products/%s/tokens/%s",
		url.PathEscape(g.PackageName), url.PathEscape(productID), url.PathEscape(purchaseToken))

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return Receipt{}, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	res, err := g.HTTP.Do(req)
	if err != nil {
		return Receipt{}, fmt.Errorf("purchase: verify request: %w", err)
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(res.Body, 1<<16))

	switch {
	case res.StatusCode == http.StatusNotFound || res.StatusCode == http.StatusBadRequest:
		return Receipt{}, ErrUnverified
	case res.StatusCode != http.StatusOK:
		// 401/403 is a credentials or permissions problem, 5xx is Google's:
		// both are ours to fix or retry, and neither means the player lied.
		return Receipt{}, fmt.Errorf("purchase: verify %d: %s", res.StatusCode, string(body))
	}

	var out struct {
		PurchaseState      *int   `json:"purchaseState"`
		AcknowledgementSt  *int   `json:"acknowledgementState"`
		OrderID            string `json:"orderId"`
		PurchaseTimeMillis string `json:"purchaseTimeMillis"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return Receipt{}, fmt.Errorf("purchase: verify body: %w", err)
	}
	if out.PurchaseState == nil || *out.PurchaseState != 0 {
		return Receipt{}, ErrNotPurchased
	}
	var at int64
	fmt.Sscan(out.PurchaseTimeMillis, &at)
	return Receipt{
		OrderID:            out.OrderID,
		PurchaseTimeMillis: at,
		Acknowledged:       out.AcknowledgementSt != nil && *out.AcknowledgementSt == 1,
	}, nil
}

// Acknowledge tells Play the purchase was delivered.
//
// This is not optional: Google refunds a purchase that is not acknowledged
// within three days, and the player would keep chips they were refunded for.
// It runs after the chips are credited — an acknowledgement that races ahead
// of the credit would be a lie.
func (g *GoogleVerifier) Acknowledge(ctx context.Context, productID, purchaseToken string) error {
	token, err := g.accessToken(ctx)
	if err != nil {
		return err
	}
	endpoint := fmt.Sprintf(
		"https://androidpublisher.googleapis.com/androidpublisher/v3/applications/%s/purchases/products/%s/tokens/%s:acknowledge",
		url.PathEscape(g.PackageName), url.PathEscape(productID), url.PathEscape(purchaseToken))
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader("{}"))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	res, err := g.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(res.Body, 1<<16))
	// 400 here is normally "already acknowledged", which is the state we want.
	if res.StatusCode >= 500 {
		return fmt.Errorf("purchase: acknowledge %d", res.StatusCode)
	}
	return nil
}
