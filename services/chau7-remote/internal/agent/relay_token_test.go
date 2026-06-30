package agent

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"strconv"
	"strings"
	"testing"
	"time"
)

// TestGenerateRelayTokenFormat locks the v2 token wire format and signature
// construction to the contract the Cloudflare relay verifies
// (services/chau7-relay/src/token.js). If this test and the relay ever drift,
// authentication breaks in production, so the assertions are deliberately exact.
func TestGenerateRelayTokenFormat(t *testing.T) {
	const (
		deviceID = "11111111-2222-3333-4444-555555555555"
		role     = "mac"
		scope    = "connect"
		hmacKey  = "unit-test-hmac-key-0001"
	)

	token := generateRelayToken(deviceID, role, scope, hmacKey)

	parts := strings.Split(token, ".")
	if len(parts) != 5 {
		t.Fatalf("expected 5 dot-separated parts, got %d: %q", len(parts), token)
	}
	version, ts, nonce, gotScope, sig := parts[0], parts[1], parts[2], parts[3], parts[4]

	if version != "v2" {
		t.Errorf("version = %q, want v2", version)
	}
	if gotScope != scope {
		t.Errorf("scope = %q, want %q", gotScope, scope)
	}
	if _, err := strconv.ParseInt(ts, 10, 64); err != nil {
		t.Errorf("timestamp %q is not an integer: %v", ts, err)
	}
	if _, err := base64.RawURLEncoding.DecodeString(nonce); err != nil {
		t.Errorf("nonce %q is not raw-url base64: %v", nonce, err)
	}

	// Recompute the signature exactly as the relay does and compare.
	msg := "v2:" + deviceID + ":" + role + ":" + scope + ":" + ts + ":" + nonce
	mac := hmac.New(sha256.New, []byte(hmacKey))
	mac.Write([]byte(msg))
	want := base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	if sig != want {
		t.Errorf("signature mismatch:\n got %q\nwant %q", sig, want)
	}
}

func TestGenerateRelayTokenNonceIsUnique(t *testing.T) {
	a := generateRelayToken("d", "mac", "push", "s")
	b := generateRelayToken("d", "mac", "push", "s")
	if strings.Split(a, ".")[2] == strings.Split(b, ".")[2] {
		t.Error("expected distinct nonces across mints")
	}
}

func TestGenerateRelayTokenTimestampIsFresh(t *testing.T) {
	token := generateRelayToken("d", "ios", "pending", "s")
	ts, err := strconv.ParseInt(strings.Split(token, ".")[1], 10, 64)
	if err != nil {
		t.Fatalf("bad ts: %v", err)
	}
	if delta := time.Now().Unix() - ts; delta < 0 || delta > 5 {
		t.Errorf("timestamp not fresh, delta=%ds", delta)
	}
}
