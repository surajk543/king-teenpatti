package assets

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"
	"time"
)

// amzDateLayout is X-Amz-Date's form: ISO 8601 basic, UTC.
const amzDateLayout = "20060102T150405Z"

// presignGET is AWS Signature Version 4 carried in the query string, for a GET
// of path on host (docs.aws.amazon.com/AmazonS3/latest/API/sigv4-query-string-auth.html):
// the URL with X-Amz-Algorithm, X-Amz-Credential, X-Amz-Date, X-Amz-Expires and
// X-Amz-SignedHeaders in canonical order and X-Amz-Signature last, signed at
// `at` and valid for `expires`. host is the one signed header and the payload
// is UNSIGNED-PAYLOAD, as every presigned GET's is. signingKey is
// signingKeyFor(secret, at's date, region, service), passed in so a caller
// signing many URLs on one day derives it once.
func presignGET(host, path, accessKeyID string, signingKey []byte, region, service string, at time.Time, expires time.Duration) string {
	at = at.UTC()
	amzDate := at.Format(amzDateLayout)
	scope := amzDate[:8] + "/" + region + "/" + service + "/aws4_request"
	canonicalURI := uriEncode(path, true)
	// Already in canonical order: the five parameter names sort as written.
	query := "X-Amz-Algorithm=AWS4-HMAC-SHA256" +
		"&X-Amz-Credential=" + uriEncode(accessKeyID+"/"+scope, false) +
		"&X-Amz-Date=" + amzDate +
		"&X-Amz-Expires=" + strconv.FormatInt(int64(expires/time.Second), 10) +
		"&X-Amz-SignedHeaders=host"
	canonicalRequest := "GET\n" +
		canonicalURI + "\n" +
		query + "\n" +
		"host:" + host + "\n" +
		"\n" +
		"host\n" +
		"UNSIGNED-PAYLOAD"
	digest := sha256.Sum256([]byte(canonicalRequest))
	stringToSign := "AWS4-HMAC-SHA256\n" + amzDate + "\n" + scope + "\n" + hex.EncodeToString(digest[:])
	signature := hex.EncodeToString(hmacSHA256(signingKey, stringToSign))
	return "https://" + host + canonicalURI + "?" + query + "&X-Amz-Signature=" + signature
}

// signingKeyFor is SigV4's derived key: HMAC("AWS4"+secret, date) chained
// through the region, the service and "aws4_request". date is YYYYMMDD.
func signingKeyFor(secret, date, region, service string) []byte {
	k := hmacSHA256([]byte("AWS4"+secret), date)
	k = hmacSHA256(k, region)
	k = hmacSHA256(k, service)
	return hmacSHA256(k, "aws4_request")
}

func hmacSHA256(key []byte, data string) []byte {
	h := hmac.New(sha256.New, key)
	h.Write([]byte(data))
	return h.Sum(nil)
}

// uriEncode is SigV4's URI encoding: every byte but the unreserved characters
// (A–Z a–z 0–9 - _ . ~) as %XX in upper-case hex, and '/' kept as it is when
// keepSlash (a path) and encoded otherwise (a query value). S3 encodes a key
// once, never twice.
func uriEncode(s string, keepSlash bool) string {
	const hexDigits = "0123456789ABCDEF"
	var b strings.Builder
	b.Grow(len(s))
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case 'A' <= c && c <= 'Z', 'a' <= c && c <= 'z', '0' <= c && c <= '9',
			c == '-', c == '_', c == '.', c == '~':
			b.WriteByte(c)
		case c == '/' && keepSlash:
			b.WriteByte(c)
		default:
			b.WriteByte('%')
			b.WriteByte(hexDigits[c>>4])
			b.WriteByte(hexDigits[c&15])
		}
	}
	return b.String()
}
