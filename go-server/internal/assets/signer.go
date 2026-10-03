// Package assets signs the catalogue's art for the phones (owner, 1 Oct
// 2026: "upload the artifacts in R2 cloudflare … in database store the
// location of these uploaded assets", then: "backend will give signed urls
// valid for 10 min, UI will download and save in phone disk or cache, when
// user login again, it will see the path of assets is changed, so the UI will
// ask for new signed url for changed asset path stored in db").
//
// The art — the profile pictures, table pictures, emojis, badges and level
// art the seed names — lives in a PRIVATE Cloudflare R2 bucket, moved there
// from Google Drive by tools/r2/migrate_drive_assets.py; the card backs (3 Oct
// 2026) were uploaded by the owner straight into its cards/ folder, under
// their own names, spaces and capitals included. The database stores each
// file's LOCATION, its R2 URL, path-style on the account's S3 endpoint:
//
//	https://<account>.r2.cloudflarestorage.com/<bucket>/<key>
//
// That is what every route hands out (a picture's url, an account's
// avatarUrl, a badge's assetUrl …), unchanged — the stable name a phone keys
// its cache by — and nobody can open it as it stands. A phone that needs a
// file it does not have asks for it signed (POST /api/assets/sign,
// auth.Handler.SignAssets), and Signer.Sign turns the location into a
// presigned GET (AWS Signature Version 4 in the query string, which R2
// accepts) valid for SignedFor: ten minutes, enough to download the file once.
// A changed file is a new key, so a new location, which the phone sees it does
// not have.
package assets

import (
	"fmt"
	"regexp"
	"strings"
	"time"
)

const (
	// SignedFor is how long a signed URL lasts from the moment it is handed
	// out: ten minutes (owner, 1 Oct 2026).
	SignedFor = 10 * time.Minute
	// skew is how far back a URL is signed: X-Amz-Date is a minute before
	// now and X-Amz-Expires a minute longer, so a clock running a little
	// ahead of Cloudflare's never hands out a URL that is not valid yet, and
	// the URL still dies SignedFor after it was handed out.
	skew = time.Minute
	// region and service are what R2 expects in a SigV4 scope.
	region  = "auto"
	service = "s3"
)

// Config is the bucket the art is in and the key pair that signs it:
// config.AssetsConfig, which reads R2_ACCOUNT_ID, R2_ACCESS_KEY_ID,
// R2_SECRET_ACCESS_KEY and R2_BUCKET_NAME.
type Config struct {
	AccountID       string
	AccessKeyID     string
	SecretAccessKey string
	Bucket          string
}

var (
	accountPattern = regexp.MustCompile(`^[a-z0-9]{1,64}$`)
	bucketPattern  = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$`)
	// keyPattern is the keys this bucket's locations use, as a LOCATION
	// writes them: a folder of lower-case letters, digits, '-' and '_', any
	// segments after it of those and '.', and a file name that may also hold
	// upper-case letters and spaces — the owner's card backs keep the names
	// they were uploaded under (3 Oct 2026: "cards/Royal Owl with fox.jpg").
	// A space is written %20, the one escape a location carries, and only
	// between two other characters: no raw space, no space at either end of
	// the name, no other %-escape (%2F, %2e, %25 …), no empty segment; and
	// Key refuses '..' anywhere. A key of any other shape is not signed.
	// Every key the old rule took — lower case, no spaces — is still taken.
	keyPattern = regexp.MustCompile(`^[a-z0-9_-]+(?:/[a-z0-9_.-]+)*/[A-Za-z0-9_.-]+(?:(?:%20)+[A-Za-z0-9_.-]+)*$`)
)

// locationSpace is how a location writes a space in a key: the one escape
// keyPattern allows.
const locationSpace = "%20"

// Signer signs the locations of one bucket. Safe for concurrent use: it holds
// nothing that changes.
type Signer struct {
	host, bucket string
	// prefix is every location's start: "https://<host>/<bucket>/".
	prefix      string
	accessKeyID string
	secret      string
	now         func() time.Time
}

// New is a Signer for cfg's bucket. now is the clock (time.Now in the
// server). An account id or bucket name that cannot be part of an R2 URL, or
// a missing key, is an error.
func New(cfg Config, now func() time.Time) (*Signer, error) {
	account := strings.ToLower(strings.TrimSpace(cfg.AccountID))
	bucket := strings.TrimSpace(cfg.Bucket)
	switch {
	case !accountPattern.MatchString(account):
		return nil, fmt.Errorf("R2_ACCOUNT_ID must be the account's id (letters and digits), got %q", cfg.AccountID)
	case !bucketPattern.MatchString(bucket):
		return nil, fmt.Errorf("R2_BUCKET_NAME must be an R2 bucket name (3–63 lower-case letters, digits and hyphens), got %q", cfg.Bucket)
	case strings.TrimSpace(cfg.AccessKeyID) == "" || strings.TrimSpace(cfg.SecretAccessKey) == "":
		return nil, fmt.Errorf("R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY must both be set")
	}
	if now == nil {
		now = time.Now
	}
	host := account + ".r2.cloudflarestorage.com"
	return &Signer{
		host:        host,
		bucket:      bucket,
		prefix:      "https://" + host + "/" + bucket + "/",
		accessKeyID: strings.TrimSpace(cfg.AccessKeyID),
		secret:      strings.TrimSpace(cfg.SecretAccessKey),
		now:         now,
	}, nil
}

// Location is the URL the database stores for the object at key — what the
// seed writes and what Sign signs — with each space of the key written %20
// (owner, 3 Oct 2026: a card back's key is its file's own name, "cards/Brutal
// Demon.jpg"), so Location(Key(u)) is u.
func (s *Signer) Location(key string) string {
	return s.prefix + strings.ReplaceAll(strings.TrimPrefix(key, "/"), " ", locationSpace)
}

// Key is the object key of a location in this bucket, and whether u is one: a
// URL of Location's form whose key has keyPattern's shape, with no query or
// fragment. Another host, another bucket, a relative path, a URL already
// signed or "" is not. The key comes back DECODED — "cards/Brutal Demon.jpg"
// for ".../cards/Brutal%20Demon.jpg" — which is the object's name in the
// bucket and what presignGET encodes, once, into the signed path.
func (s *Signer) Key(u string) (string, bool) {
	if s == nil || !strings.HasPrefix(u, s.prefix) {
		return "", false
	}
	raw := u[len(s.prefix):]
	if !keyPattern.MatchString(raw) {
		return "", false
	}
	key := strings.ReplaceAll(raw, locationSpace, " ")
	if strings.Contains(key, "..") {
		return "", false
	}
	return key, true
}

// Sign is the location u as a URL a phone can open, presigned for a GET, and
// the moment it stops working: SignedFor from now. ok is false — and nothing
// is signed — for anything Key does not take as a location in this bucket.
func (s *Signer) Sign(u string) (signed string, expiresAt time.Time, ok bool) {
	if s == nil {
		return "", time.Time{}, false
	}
	return s.signAt(u, s.now())
}

// SignAll signs every location in urls that Sign would, on one reading of the
// clock, so they all stop working together, at expiresAt; anything else is
// left out of the map.
func (s *Signer) SignAll(urls []string) (signed map[string]string, expiresAt time.Time) {
	signed = map[string]string{}
	if s == nil {
		return signed, time.Time{}
	}
	now := s.now()
	for _, u := range urls {
		if link, at, ok := s.signAt(u, now); ok {
			signed[u], expiresAt = link, at
		}
	}
	if expiresAt.IsZero() {
		expiresAt = now.UTC().Add(SignedFor)
	}
	return signed, expiresAt
}

func (s *Signer) signAt(u string, now time.Time) (signed string, expiresAt time.Time, ok bool) {
	key, ok := s.Key(u)
	if !ok {
		return "", time.Time{}, false
	}
	now = now.UTC()
	at := now.Add(-skew).Truncate(time.Second)
	expires := SignedFor + now.Sub(at)
	// X-Amz-Expires is whole seconds: round up, so the URL never dies early.
	if rem := expires % time.Second; rem != 0 {
		expires += time.Second - rem
	}
	signingKey := signingKeyFor(s.secret, at.Format("20060102"), region, service)
	return presignGET(s.host, "/"+s.bucket+"/"+key, s.accessKeyID, signingKey, region, service, at, expires),
		at.Add(expires), true
}
