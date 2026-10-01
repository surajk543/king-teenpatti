package assets

import (
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"
)

// AWS's own worked example of a presigned GET (Amazon S3 API reference,
// "Authenticating Requests: Using Query Parameters (AWS Signature Version 4)"):
// the signature is the one AWS publishes, so the canonical request, the string
// to sign and the derived key are all exactly SigV4's.
func TestPresigningReproducesAWSPublishedExample(t *testing.T) {
	at := time.Date(2013, 5, 24, 0, 0, 0, 0, time.UTC)
	key := signingKeyFor("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", "20130524", "us-east-1", "s3")
	got := presignGET("examplebucket.s3.amazonaws.com", "/test.txt", "AKIAIOSFODNN7EXAMPLE", key, "us-east-1", "s3", at, 24*time.Hour)
	want := "https://examplebucket.s3.amazonaws.com/test.txt" +
		"?X-Amz-Algorithm=AWS4-HMAC-SHA256" +
		"&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request" +
		"&X-Amz-Date=20130524T000000Z" +
		"&X-Amz-Expires=86400" +
		"&X-Amz-SignedHeaders=host" +
		"&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"
	if got != want {
		t.Fatalf("presigned URL\n got %s\nwant %s", got, want)
	}
}

func TestURIEncodingKeepsOnlyUnreservedCharacters(t *testing.T) {
	cases := []struct {
		in        string
		keepSlash bool
		want      string
	}{
		{"profile_pictures/love-sheep.json", true, "profile_pictures/love-sheep.json"},
		{"a b/c~d.e", true, "a%20b/c~d.e"},
		{"AKID/20261001/auto/s3/aws4_request", false, "AKID%2F20261001%2Fauto%2Fs3%2Faws4_request"},
		{"ünï", true, "%C3%BCn%C3%AF"},
		{"a+b=c&d", true, "a%2Bb%3Dc%26d"},
	}
	for _, c := range cases {
		if got := uriEncode(c.in, c.keepSlash); got != c.want {
			t.Errorf("uriEncode(%q, %t) = %q, want %q", c.in, c.keepSlash, got, c.want)
		}
	}
}

func testSigner(t *testing.T, now func() time.Time) *Signer {
	t.Helper()
	s, err := New(Config{AccountID: "0123456789abcdef0123456789abcdef", AccessKeyID: "AKIDTEST",
		SecretAccessKey: "secret", Bucket: "king-teenpatti"}, now)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

// The location is what the database stores: path-style on the account's S3
// endpoint, the bucket first.
func TestALocationIsTheObjectsURLOnTheAccountsEndpoint(t *testing.T) {
	s := testSigner(t, time.Now)
	want := "https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com/king-teenpatti/emojis/angry.json"
	if got := s.Location("emojis/angry.json"); got != want {
		t.Fatalf("Location = %q, want %q", got, want)
	}
	if got := s.Location("/emojis/angry.json"); got != want {
		t.Fatalf("Location of a key with a leading slash = %q, want %q", got, want)
	}
	if key, ok := s.Key(want); !ok || key != "emojis/angry.json" {
		t.Fatalf("Key(%q) = %q, %t", want, key, ok)
	}
}

// A location comes back presigned for ten minutes from the moment it is asked
// for: signed a minute back, for eleven, so a clock a little ahead of
// Cloudflare's cannot hand out a URL that is not valid yet.
func TestALocationIsSignedForTenMinutesFromNow(t *testing.T) {
	now := time.Date(2026, 10, 1, 15, 4, 5, 0, time.UTC)
	s := testSigner(t, func() time.Time { return now })
	signed, expiresAt, ok := s.Sign(s.Location("profile_pictures/love-sheep.json"))
	if !ok {
		t.Fatal("a location of this bucket was not signed")
	}
	if !expiresAt.Equal(now.Add(SignedFor)) {
		t.Fatalf("expiresAt = %s, want %s", expiresAt, now.Add(SignedFor))
	}
	u, err := url.Parse(signed)
	if err != nil {
		t.Fatal(err)
	}
	if u.Scheme != "https" || u.Host != "0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com" ||
		u.Path != "/king-teenpatti/profile_pictures/love-sheep.json" {
		t.Fatalf("signed URL %s points elsewhere", signed)
	}
	q := u.Query()
	want := map[string]string{
		"X-Amz-Algorithm":     "AWS4-HMAC-SHA256",
		"X-Amz-Credential":    "AKIDTEST/20261001/auto/s3/aws4_request",
		"X-Amz-Date":          "20261001T150305Z",
		"X-Amz-Expires":       "660",
		"X-Amz-SignedHeaders": "host",
	}
	for k, v := range want {
		if q.Get(k) != v {
			t.Errorf("%s = %q, want %q", k, q.Get(k), v)
		}
	}
	if sig := q.Get("X-Amz-Signature"); len(sig) != 64 || strings.Trim(sig, "0123456789abcdef") != "" {
		t.Errorf("X-Amz-Signature = %q, want 64 hex digits", sig)
	}
	if !strings.HasSuffix(signed, "&X-Amz-Signature="+q.Get("X-Amz-Signature")) {
		t.Errorf("the signature is not the last parameter: %s", signed)
	}
}

// A fraction of a second never shortens the ten minutes: X-Amz-Expires is
// whole seconds, rounded up.
func TestTenMinutesAreNeverCutShortByAFractionOfASecond(t *testing.T) {
	now := time.Date(2026, 10, 1, 15, 4, 5, 700_000_000, time.UTC)
	s := testSigner(t, func() time.Time { return now })
	signed, expiresAt, _ := s.Sign(s.Location("badges/regular.json"))
	q := mustQuery(t, signed)
	date, err := time.Parse(amzDateLayout, q.Get("X-Amz-Date"))
	if err != nil {
		t.Fatal(err)
	}
	if q.Get("X-Amz-Expires") != "661" {
		t.Fatalf("X-Amz-Expires = %s, want 661", q.Get("X-Amz-Expires"))
	}
	if dies := date.Add(661 * time.Second); dies.Before(now.Add(SignedFor)) || !dies.Equal(expiresAt) {
		t.Fatalf("the URL dies at %s; asked for at %s, expiresAt %s", dies, now, expiresAt)
	}
}

// Anything that is not a location in this bucket is not signed.
func TestOnlyThisBucketsLocationsAreSigned(t *testing.T) {
	s := testSigner(t, time.Now)
	for _, u := range []string{
		"",
		"/levels/newbie.json",
		"https://lh3.googleusercontent.com/a/ACg8ocK=s96-c",
		"https://drive.google.com/uc?export=download&id=1abc",
		"https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com/another-bucket/emojis/angry.json",
		"https://ffffffffffffffffffffffffffffffff.r2.cloudflarestorage.com/king-teenpatti/emojis/angry.json",
		"https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com/king-teenpatti/",
		"https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com/king-teenpatti/angry.json",
		"https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com/king-teenpatti/emojis/../secret.json",
		"https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com/king-teenpatti/emojis/Angry.json",
		"https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com/king-teenpatti/emojis/angry.json?x=1",
		"http://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com/king-teenpatti/emojis/angry.json",
	} {
		if signed, _, ok := s.Sign(u); ok || signed != "" {
			t.Errorf("Sign(%q) = %q, %t; want nothing signed", u, signed, ok)
		}
	}
	var none *Signer
	if _, _, ok := none.Sign(s.Location("emojis/angry.json")); ok {
		t.Error("a nil Signer signed a URL")
	}
}

func TestASignerNeedsAUsableBucketAndKeys(t *testing.T) {
	good := Config{AccountID: "0123456789ABCDEF0123456789abcdef", AccessKeyID: "a", SecretAccessKey: "b", Bucket: "king-teenpatti"}
	if s, err := New(good, time.Now); err != nil || !strings.HasPrefix(s.Location("x"), "https://0123456789abcdef0123456789abcdef.") {
		t.Fatalf("an upper-case account id: %v (it is a host name, so it is lower-cased)", err)
	}
	for name, cfg := range map[string]Config{
		"no account":    {AccessKeyID: "a", SecretAccessKey: "b", Bucket: "king-teenpatti"},
		"odd account":   {AccountID: "abc.def", AccessKeyID: "a", SecretAccessKey: "b", Bucket: "king-teenpatti"},
		"no bucket":     {AccountID: "abc", AccessKeyID: "a", SecretAccessKey: "b"},
		"odd bucket":    {AccountID: "abc", AccessKeyID: "a", SecretAccessKey: "b", Bucket: "King_Teenpatti"},
		"no key id":     {AccountID: "abc", SecretAccessKey: "b", Bucket: "king-teenpatti"},
		"no secret key": {AccountID: "abc", AccessKeyID: "a", Bucket: "king-teenpatti"},
	} {
		if _, err := New(cfg, time.Now); err == nil {
			t.Errorf("%s: New accepted %+v", name, cfg)
		}
	}
}

// Many requests sign at once: a Signer holds nothing that changes.
func TestSigningIsSafeFromManyGoroutines(t *testing.T) {
	now := time.Date(2026, 10, 1, 15, 4, 5, 0, time.UTC)
	s := testSigner(t, func() time.Time { return now })
	loc := s.Location("badges/royal-ace.json")
	want, _, _ := s.Sign(loc)
	var wg sync.WaitGroup
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 200; j++ {
				if got, _, _ := s.Sign(loc); got != want {
					t.Errorf("a concurrent signature differs: %s", got)
					return
				}
			}
		}()
	}
	wg.Wait()
}

func mustQuery(t *testing.T, signed string) url.Values {
	t.Helper()
	u, err := url.Parse(signed)
	if err != nil {
		t.Fatal(err)
	}
	return u.Query()
}

// A batch is signed on one reading of the clock, so every URL in it stops
// working at the same moment; what is not a location is left out.
func TestABatchIsSignedTogetherAndLeavesOutWhatIsNotALocation(t *testing.T) {
	now := time.Date(2026, 10, 1, 15, 4, 5, 0, time.UTC)
	reads := 0
	s := testSigner(t, func() time.Time { reads++; return now })
	angry, bear := s.Location("emojis/angry.json"), s.Location("profile_pictures/bear.png")
	signed, expiresAt := s.SignAll([]string{angry, "/levels/newbie.json", bear, "https://example.com/x.json"})
	if reads != 1 {
		t.Fatalf("the clock was read %d times for one batch", reads)
	}
	if len(signed) != 2 || signed[angry] == "" || signed[bear] == "" {
		t.Fatalf("SignAll = %v, want the two locations signed", signed)
	}
	if !expiresAt.Equal(now.Add(SignedFor)) {
		t.Fatalf("expiresAt = %s, want %s", expiresAt, now.Add(SignedFor))
	}
	if one, _, _ := s.Sign(angry); one != signed[angry] {
		t.Fatalf("the batch's URL differs from Sign's at the same instant:\n %s\n %s", signed[angry], one)
	}
	if none, at := s.SignAll(nil); len(none) != 0 || !at.Equal(now.Add(SignedFor)) {
		t.Fatalf("an empty batch: %v, %s", none, at)
	}
}
