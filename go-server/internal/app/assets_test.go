package app

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/surajk543/king-teenpatti/go-server/internal/auth"
	"github.com/surajk543/king-teenpatti/go-server/internal/config"
)

// seededAssets is where the seed's catalogue art lives (owner, 1 Oct 2026):
// the R2 bucket every file moved to from Google Drive. A row stores this
// followed by the file's key.
const seededAssets = "https://a91cb23b3b93a35dd9ea50db7b855e18.r2.cloudflarestorage.com/king-teenpatti/"

// withR2 gives a test server R2 keys for the seed's bucket: test keys, so
// nothing it signs opens a real file, but every URL has the shape it would.
func withR2(cfg *config.Config) {
	cfg.Assets = config.AssetsConfig{R2AccountID: "a91cb23b3b93a35dd9ea50db7b855e18",
		R2AccessKeyID: "AKIDTEST", R2SecretAccessKey: "test-secret", R2Bucket: "king-teenpatti"}
}

// The catalogue's art on the real wiring (owner, 1 Oct 2026: "backend will
// give signed urls valid for 10 min … the UI will ask for new signed url for
// changed asset path stored in db"): every route hands out the LOCATION the
// database stores, unsigned — the stable name the app keys its cache by — and
// POST /api/assets/sign, for a signed-in phone, signs the locations it asks
// for that some catalogue row stores, valid ten minutes, and nothing else.
func TestRoutesHandOutLocationsAndTheSignRouteSignsThemForTenMinutes(t *testing.T) {
	a, _ := newApp(t, withR2)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()

	// The catalogue route hands out the stored location as it is.
	bear := seededAssets + "profile_pictures/bear.png"
	found := false
	for _, p := range catalogue(t, ts.URL) {
		if p.Name == "Bear" {
			found = true
			if p.URL != bear {
				t.Fatalf("GET /api/profiles hands out Bear at %q, want its location %q", p.URL, bear)
			}
		}
	}
	if !found {
		t.Fatal("the seeded catalogue has no Bear")
	}

	asked := []string{
		bear,
		seededAssets + "emojis/angry.json",
		seededAssets + "levels/32-royal-titan.json",
		seededAssets + "emojis/3.13.0.txt",             // in the bucket, named by no row
		seededAssets + "profile_pictures/nobody.png",   // named by nothing at all
		"https://lh3.googleusercontent.com/a/photo",    // somebody else's host
		"https://evil.example/king-teenpatti/emojis/x", // a look-alike
		bear, // asked twice
	}
	body, _ := json.Marshal(auth.SignAssetsRequest{URLs: asked})
	if status, raw := postRaw(t, ts.URL, "", "/api/assets/sign", string(body)); status != http.StatusUnauthorized {
		t.Fatalf("signing without a session: %d %s", status, raw)
	}

	token, _ := login(t, ts.URL, "asset-signer-device", "Asset Signer")
	before := time.Now()
	status, raw := postRaw(t, ts.URL, token, "/api/assets/sign", string(body))
	if status != http.StatusOK {
		t.Fatalf("POST /api/assets/sign: %d %s", status, raw)
	}
	var answer auth.SignAssetsResponse
	if err := json.Unmarshal(raw, &answer); err != nil {
		t.Fatal(err)
	}
	if len(answer.URLs) != 3 {
		t.Fatalf("signed %d URLs, want the three stored ones: %s", len(answer.URLs), raw)
	}
	for _, location := range asked[:3] {
		signed := answer.URLs[location]
		if !strings.HasPrefix(signed, location+"?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIDTEST%2F") {
			t.Errorf("%s came back as %q", location, signed)
			continue
		}
		u, err := url.Parse(signed)
		if err != nil {
			t.Fatal(err)
		}
		if q := u.Query(); q.Get("X-Amz-Expires") != "660" && q.Get("X-Amz-Expires") != "661" || q.Get("X-Amz-Signature") == "" {
			t.Errorf("%s is not signed for ten minutes: %s", location, signed)
		}
	}
	expires := time.UnixMilli(answer.ExpiresAt)
	if expires.Before(before.Add(10*time.Minute-time.Second)) || expires.After(time.Now().Add(10*time.Minute+2*time.Second)) {
		t.Errorf("expiresAt %s, want ten minutes from now", expires.Format(time.RFC3339))
	}

	// Too many at once, and a body that is not one.
	many := make([]string, auth.MaxSignedAssets+1)
	for i := range many {
		many[i] = fmt.Sprintf("%sprofile_pictures/p%d.png", seededAssets, i)
	}
	body, _ = json.Marshal(auth.SignAssetsRequest{URLs: many})
	if status, raw := postRaw(t, ts.URL, token, "/api/assets/sign", string(body)); status != http.StatusBadRequest ||
		!strings.Contains(string(raw), `"error":"too_many_assets"`) {
		t.Errorf("%d URLs: %d %s", len(many), status, raw)
	}
	if status, raw := postRaw(t, ts.URL, token, "/api/assets/sign", `{"urls":`); status != http.StatusBadRequest ||
		!strings.Contains(string(raw), `"error":"invalid_json"`) {
		t.Errorf("a broken body: %d %s", status, raw)
	}
	// An empty ask is an empty answer, never null.
	if status, raw := postRaw(t, ts.URL, token, "/api/assets/sign", `{"urls":[]}`); status != http.StatusOK ||
		!strings.HasPrefix(string(raw), `{"urls":{},"expiresAt":`) {
		t.Errorf("an empty ask: %d %s", status, raw)
	}
}

// A server with no R2 keys (development) cannot sign: the route says so, and
// the app draws what it cannot fetch as it draws any picture that failed.
func TestWithoutR2KeysTheSignRouteAnswersAssetsUnavailable(t *testing.T) {
	a, _ := newApp(t, nil)
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	token, _ := login(t, ts.URL, "asset-unsigned-device", "No Keys")
	status, raw := postRaw(t, ts.URL, token, "/api/assets/sign", `{"urls":["`+seededAssets+`emojis/angry.json"]}`)
	if status != http.StatusServiceUnavailable || !strings.Contains(string(raw), `"error":"assets_unavailable"`) {
		t.Fatalf("signing with no keys: %d %s", status, raw)
	}
}

// With the real keys in the environment, a URL the route signs opens the real
// file in the real bucket. Skipped unless R2_ACCOUNT_ID and the rest are set
// (set -a; . ./.env; set +a).
func TestASignedURLFromTheRouteOpensTheRealFile(t *testing.T) {
	if os.Getenv("R2_ACCOUNT_ID") == "" || os.Getenv("R2_SECRET_ACCESS_KEY") == "" {
		t.Skip("set the R2_* keys to open a real file")
	}
	a, _ := newApp(t, func(cfg *config.Config) {
		cfg.Assets = config.AssetsConfig{R2AccountID: os.Getenv("R2_ACCOUNT_ID"), R2AccessKeyID: os.Getenv("R2_ACCESS_KEY_ID"),
			R2SecretAccessKey: os.Getenv("R2_SECRET_ACCESS_KEY"), R2Bucket: os.Getenv("R2_BUCKET_NAME")}
	})
	ts := httptest.NewServer(a.Handler())
	defer ts.Close()
	token, _ := login(t, ts.URL, "asset-live-device", "Live Signer")
	royalTitan := seededAssets + "levels/32-royal-titan.json"
	status, raw := postRaw(t, ts.URL, token, "/api/assets/sign", `{"urls":["`+royalTitan+`"]}`)
	var answer auth.SignAssetsResponse
	if err := json.Unmarshal(raw, &answer); status != http.StatusOK || err != nil || answer.URLs[royalTitan] == "" {
		t.Fatalf("signing Royal Titan's art: %d %s %v", status, raw, err)
	}
	res, err := http.Get(answer.URLs[royalTitan])
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	data, _ := io.ReadAll(res.Body)
	if res.StatusCode != http.StatusOK || !json.Valid(data) {
		t.Fatalf("GET of the signed URL: %d, %d bytes", res.StatusCode, len(data))
	}
}
