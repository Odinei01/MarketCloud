package awsv4

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
	"time"
)

const algorithm = "AWS4-HMAC-SHA256"

// Credentials holds AWS IAM credentials for SigV4 signing.
type Credentials struct {
	AccessKeyID     string
	SecretAccessKey string
	Region          string
	Service         string // e.g. "advertising"
}

// IsEmpty returns true when no real credentials are configured.
func (c Credentials) IsEmpty() bool {
	return c.AccessKeyID == "" || c.SecretAccessKey == ""
}

// SignRequest adds an AWS SigV4 Authorization header to req.
// The request body must be readable; pass bodyBytes separately so it
// can be used for signing and re-set on the request.
func SignRequest(req *http.Request, bodyBytes []byte, creds Credentials) error {
	t := time.Now().UTC()
	date := t.Format("20060102")
	datetime := t.Format("20060102T150405Z")

	// Set required headers before signing
	req.Header.Set("X-Amz-Date", datetime)
	req.Header.Set("Host", req.URL.Host)

	// Canonical URI
	canonicalURI := req.URL.EscapedPath()
	if canonicalURI == "" {
		canonicalURI = "/"
	}

	// Canonical query string (sorted)
	query := req.URL.Query()
	keys := make([]string, 0, len(query))
	for k := range query {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var qParts []string
	for _, k := range keys {
		for _, v := range query[k] {
			qParts = append(qParts, urlEncode(k)+"="+urlEncode(v))
		}
	}
	canonicalQS := strings.Join(qParts, "&")

	// Canonical headers (host + x-amz-date + content-type if present)
	var signedHeadersList []string
	var canonicalHeaderLines []string

	headersToSign := map[string]string{}
	for k, vals := range req.Header {
		lk := strings.ToLower(k)
		if lk == "host" || lk == "x-amz-date" || lk == "content-type" || strings.HasPrefix(lk, "x-amz-") {
			headersToSign[lk] = strings.TrimSpace(vals[0])
		}
	}
	headersToSign["host"] = req.URL.Host

	for k := range headersToSign {
		signedHeadersList = append(signedHeadersList, k)
	}
	sort.Strings(signedHeadersList)

	for _, k := range signedHeadersList {
		canonicalHeaderLines = append(canonicalHeaderLines, k+":"+headersToSign[k])
	}

	canonicalHeaders := strings.Join(canonicalHeaderLines, "\n") + "\n"
	signedHeaders := strings.Join(signedHeadersList, ";")

	// Payload hash
	payloadHash := sha256hex(bodyBytes)

	// Canonical request
	canonicalRequest := strings.Join([]string{
		req.Method,
		canonicalURI,
		canonicalQS,
		canonicalHeaders,
		signedHeaders,
		payloadHash,
	}, "\n")

	// Credential scope
	credScope := fmt.Sprintf("%s/%s/%s/aws4_request", date, creds.Region, creds.Service)

	// String to sign
	stringToSign := strings.Join([]string{
		algorithm,
		datetime,
		credScope,
		sha256hex([]byte(canonicalRequest)),
	}, "\n")

	// Signing key
	signingKey := derivedKey(creds.SecretAccessKey, date, creds.Region, creds.Service)

	// Signature
	sig := hex.EncodeToString(hmacSHA256(signingKey, []byte(stringToSign)))

	// Authorization header
	auth := fmt.Sprintf("%s Credential=%s/%s, SignedHeaders=%s, Signature=%s",
		algorithm, creds.AccessKeyID, credScope, signedHeaders, sig)

	req.Header.Set("Authorization", auth)
	return nil
}

// NewSignedRequest creates an *http.Request with a body and SigV4 auth header.
func NewSignedRequest(ctx interface{ Deadline() (time.Time, bool); Done() <-chan struct{}; Err() error; Value(interface{}) interface{} },
	method, url string, body io.Reader, bodyBytes []byte, creds Credentials,
) (*http.Request, error) {
	req, err := http.NewRequest(method, url, body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	if err := SignRequest(req, bodyBytes, creds); err != nil {
		return nil, err
	}
	return req, nil
}

func derivedKey(secret, date, region, service string) []byte {
	kDate := hmacSHA256([]byte("AWS4"+secret), []byte(date))
	kRegion := hmacSHA256(kDate, []byte(region))
	kService := hmacSHA256(kRegion, []byte(service))
	return hmacSHA256(kService, []byte("aws4_request"))
}

func hmacSHA256(key, data []byte) []byte {
	h := hmac.New(sha256.New, key)
	h.Write(data)
	return h.Sum(nil)
}

func sha256hex(data []byte) string {
	h := sha256.Sum256(data)
	return hex.EncodeToString(h[:])
}

func urlEncode(s string) string {
	const safe = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if strings.IndexByte(safe, c) >= 0 {
			b.WriteByte(c)
		} else {
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}
