package assets

import (
	"io"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"
)

// A real object in the real bucket opens with the URL Sign hands out, and not
// with a tampered one — the check that R2 accepts what this package signs.
// Skipped unless the four R2 keys are in the environment and R2_LIVE_KEY names
// an object to fetch — by its key as the bucket names it, so a card back's
// with its spaces (Location writes them %20):
//
//	set -a; . ./.env; set +a
//	R2_LIVE_KEY=emojis/angry.json go test ./internal/assets -run Live -v
//	R2_LIVE_KEY='cards/Royal Owl with fox.jpg' go test ./internal/assets -run Live -v
func TestALiveR2ObjectOpensWithItsSignedURLAndOnlyWithIt(t *testing.T) {
	key := os.Getenv("R2_LIVE_KEY")
	if key == "" || os.Getenv("R2_ACCOUNT_ID") == "" {
		t.Skip("set the R2_* keys and R2_LIVE_KEY to fetch a real object")
	}
	s, err := New(Config{
		AccountID:       os.Getenv("R2_ACCOUNT_ID"),
		AccessKeyID:     os.Getenv("R2_ACCESS_KEY_ID"),
		SecretAccessKey: os.Getenv("R2_SECRET_ACCESS_KEY"),
		Bucket:          os.Getenv("R2_BUCKET_NAME"),
	}, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	client := &http.Client{Timeout: 30 * time.Second}
	get := func(u string) (int, int) {
		t.Helper()
		res, err := client.Get(u)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		body, _ := io.ReadAll(res.Body)
		return res.StatusCode, len(body)
	}

	location := s.Location(key)
	if status, _ := get(location); status == http.StatusOK {
		t.Fatalf("the bucket answers an unsigned GET of %s: it should be private", key)
	}
	signed, expiresAt, ok := s.Sign(location)
	if !ok {
		t.Fatalf("%s is not a location this Signer signs", location)
	}
	status, size := get(signed)
	if status != http.StatusOK || size == 0 {
		t.Fatalf("GET of the signed URL for %s: %d, %d bytes", key, status, size)
	}
	t.Logf("%s: %d bytes through a URL valid until %s", key, size, expiresAt.Format(time.RFC3339))
	tampered := signed[:len(signed)-1] + map[bool]string{true: "0", false: "1"}[!strings.HasSuffix(signed, "0")]
	if status, _ := get(tampered); status == http.StatusOK {
		t.Fatalf("a tampered signature opened %s", key)
	}
	// Signed eleven minutes ago, it has died: Cloudflare keeps the ten.
	past := *s
	past.now = func() time.Time { return time.Now().Add(-SignedFor - time.Minute) }
	stale, _, _ := past.Sign(location)
	if status, _ := get(stale); status == http.StatusOK {
		t.Fatalf("a URL signed %s ago still opened %s", SignedFor+time.Minute, key)
	}
}
