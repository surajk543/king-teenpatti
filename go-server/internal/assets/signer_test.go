package assets

import (
	"math/rand/v2"
	"net/url"
	"regexp"
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
		"https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com/king-teenpatti/Emojis/angry.json",
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

// ownersCards are the card backs the owner uploaded straight to the bucket's
// cards/ folder (3 Oct 2026), under their own file names — capitals, spaces
// and "Royal Owl with fox.jpg"'s lower-case f included. Royal Fox is the
// app's bundled default and no catalogue row, but its file is there too.
var ownersCards = []string{
	"cards/Brutal Demon.jpg", "cards/Demon Hell.jpg", "cards/Dragon Hunter.jpg", "cards/Royal Lion.jpg",
	"cards/Royal Majestic Fox.jpg", "cards/Royal Owl with fox.jpg", "cards/Royal Tiger.jpg", "cards/Royal White Tiger.jpg",
	"cards/Royal Fox.jpg",
	"cards/Flower 1.jpg", "cards/Flower 2.jpg", "cards/Flower 3.jpg", "cards/Flower 4.jpg", "cards/Flower 5.jpg",
}

// A card back's location writes each space of its key as %20 — the one escape
// a location carries — and comes back from Key with its spaces, which is the
// object's name in the bucket. Signed, the path carries the key encoded once,
// exactly as SigV4 canonicalises it for S3, so the URL a phone opens is the
// location itself with the signature after it.
func TestACardBacksLocationKeepsItsOwnersFileNameAndIsSigned(t *testing.T) {
	now := time.Date(2026, 10, 3, 9, 30, 0, 0, time.UTC)
	s := testSigner(t, func() time.Time { return now })
	const prefix = "https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com/king-teenpatti/"
	if got, want := s.Location("cards/Brutal Demon.jpg"), prefix+"cards/Brutal%20Demon.jpg"; got != want {
		t.Fatalf("Location = %q, want %q", got, want)
	}
	if got, want := s.Location("cards/Royal Owl with fox.jpg"), prefix+"cards/Royal%20Owl%20with%20fox.jpg"; got != want {
		t.Fatalf("Location = %q, want %q", got, want)
	}
	for _, key := range ownersCards {
		location := s.Location(key)
		if strings.Contains(location, " ") || strings.Count(location, "%20") != strings.Count(key, " ") {
			t.Errorf("Location(%q) = %q: every space must be %%20 and nothing else escaped", key, location)
		}
		if got, ok := s.Key(location); !ok || got != key {
			t.Errorf("Key(%q) = %q, %t; want %q", location, got, ok, key)
		}
		signed, expiresAt, ok := s.Sign(location)
		if !ok {
			t.Errorf("%s was not signed", location)
			continue
		}
		if !expiresAt.Equal(now.Add(SignedFor)) {
			t.Errorf("%s: expiresAt %s", key, expiresAt)
		}
		if !strings.HasPrefix(signed, location+"?X-Amz-Algorithm=AWS4-HMAC-SHA256&") {
			t.Errorf("the signed URL does not start with the location: %s", signed)
		}
		u, err := url.Parse(signed)
		if err != nil {
			t.Fatal(err)
		}
		if want := "/king-teenpatti/" + strings.ReplaceAll(key, " ", "%20"); u.EscapedPath() != want || u.Path != "/king-teenpatti/"+key {
			t.Errorf("signed path %q (decoded %q), want %q", u.EscapedPath(), u.Path, want)
		}
		// The signature is SigV4's over the key encoded ONCE (S3's rule): the
		// same URL presignGET makes from the decoded key.
		at := now.Add(-skew)
		want := presignGET(s.host, "/king-teenpatti/"+key, "AKIDTEST", signingKeyFor("secret", at.Format("20060102"), region, service),
			region, service, at, SignedFor+skew)
		if signed != want {
			t.Errorf("%s signed as\n %s\nwant\n %s", key, signed, want)
		}
	}
	if !strings.Contains(mustSign(t, s, "cards/Brutal Demon.jpg"), "/cards/Brutal%20Demon.jpg?") {
		t.Error("the presigned path does not carry /cards/Brutal%20Demon.jpg")
	}
}

func mustSign(t *testing.T, s *Signer, key string) string {
	t.Helper()
	signed, _, ok := s.Sign(s.Location(key))
	if !ok {
		t.Fatalf("%s was not signed", key)
	}
	return signed
}

// The key rule stays strict where it was widened: capitals and spaces are a
// FILE NAME's, a space is %20 between two other characters and nothing else
// is escaped. Each of these is refused, and nothing is signed.
func TestAFileNameMayHoldCapitalsAndSpacesAndNothingElseIsWidened(t *testing.T) {
	s := testSigner(t, time.Now)
	const prefix = "https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com/king-teenpatti/"
	for _, key := range []string{
		"cards/Brutal Demon.jpg",          // a raw space: a location writes it %20
		"cards/%20Brutal.jpg",             // a space opening the name
		"cards/Brutal.jpg%20",             // a space closing it
		"cards/Brutal%20Demon.jpg%20",     // …after a space inside it
		"cards/Brutal%2FDemon.jpg",        // an escaped slash
		"cards/Brutal%2fDemon.jpg",        // in lower case
		"cards/%2e%2e/secret.jpg",         // escaped dots
		"cards/Brutal%2520Demon.jpg",      // an escaped percent
		"cards/Brutal%2Demon.jpg",         // an escape that is not %20
		"cards/Brutal%Demon.jpg",          // a bare percent
		"cards/Brutal%20%2FDemon.jpg",     // a space, then a slash
		"cards//Brutal.jpg",               // an empty segment
		"cards/",                          // no file name
		"cards",                           // no folder
		"Cards/Brutal.jpg",                // a folder in capitals
		"my%20cards/Brutal.jpg",           // a folder with a space
		"cards/Royal%20..%20Fox.jpg",      // '..' with spaces round it
		"cards/../Brutal.jpg",             // '..' as a segment
		"cards/Brutal+Demon.jpg",          // a plus
		"cards/Brütal.jpg",                // a letter outside ASCII
		"cards/Brutal%20Demon.jpg#top",    // a fragment
		"cards/Brutal%20Demon.jpg?X-Amz-", // already signed
	} {
		if got, ok := s.Key(prefix + key); ok {
			t.Errorf("Key(%q) = %q; want it refused", key, got)
		}
		if signed, _, ok := s.Sign(prefix + key); ok || signed != "" {
			t.Errorf("Sign(%q) = %q; want nothing signed", key, signed)
		}
	}
	// A capital is a file name's and nobody else's.
	for _, key := range []string{"emojis/Angry.json", "levels/sub/Royal-Titan.json"} {
		if got, ok := s.Key(prefix + key); !ok || got != key {
			t.Errorf("Key(%q) = %q, %t; a file name may hold capitals", key, got, ok)
		}
	}
	if _, ok := s.Key(prefix + "levels/Sub/royal-titan.json"); ok {
		t.Error("a folder below the first may not hold capitals either")
	}
}

// Every key the rule took before card backs widened it is taken exactly as
// it was: Key returns it unchanged, Location writes it unchanged, and it is
// signed over the same path. Checked on the seed's shapes and on every short
// string of the old alphabet a fixed generator makes.
func TestEveryKeyTheOldRuleTookIsStillTakenUnchanged(t *testing.T) {
	now := time.Date(2026, 10, 3, 9, 30, 0, 0, time.UTC)
	s := testSigner(t, func() time.Time { return now })
	const prefix = "https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com/king-teenpatti/"
	old := regexp.MustCompile(`^[a-z0-9_-]+(/[a-z0-9_.-]+)+$`)
	keys := []string{
		"profile_pictures/love-sheep.json", "profile_pictures/bear.png", "table_pictures/thank-you-day.json",
		"emojis/angry.json", "badges/royal-ace.json", "levels/01-newbie.json", "levels/32-royal-titan.json",
		"emojis/3.13.0.txt", "a/b/c.d", "x_y/z-1/2.3",
	}
	const alphabet = "ab0_-./"
	rng := rand.New(rand.NewPCG(3, 10))
	for range 20000 {
		b := make([]byte, 1+rng.IntN(12))
		for i := range b {
			b[i] = alphabet[rng.IntN(len(alphabet))]
		}
		keys = append(keys, string(b))
	}
	taken := 0
	for _, key := range keys {
		if !old.MatchString(key) || strings.Contains(key, "..") {
			continue
		}
		taken++
		location := s.Location(key)
		if location != prefix+key {
			t.Fatalf("Location(%q) = %q, want %q", key, location, prefix+key)
		}
		if got, ok := s.Key(location); !ok || got != key {
			t.Fatalf("Key(%q) = %q, %t: the old rule took it", location, got, ok)
		}
		signed, _, ok := s.Sign(location)
		if !ok || !strings.HasPrefix(signed, location+"?") {
			t.Fatalf("%q signs as %q, %t", key, signed, ok)
		}
	}
	if taken < 200 {
		t.Fatalf("only %d keys of the old shape were tried", taken)
	}
}

// Location and Key undo each other, spaces and all.
func TestLocationAndKeyUndoEachOther(t *testing.T) {
	s := testSigner(t, time.Now)
	for _, key := range append([]string{"emojis/angry.json", "levels/sub/x.json", "cards/A B C.jpg"}, ownersCards...) {
		location := s.Location(key)
		got, ok := s.Key(location)
		if !ok || got != key {
			t.Errorf("Key(Location(%q)) = %q, %t", key, got, ok)
		}
		if back := s.Location(got); back != location {
			t.Errorf("Location(Key(%q)) = %q", location, back)
		}
	}
}
