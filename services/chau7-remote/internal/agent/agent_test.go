package agent

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"testing"
	"time"

	"chau7-remote/internal/protocol"
)

func TestIsPairRequestAuthorizedAcceptsValidPairingCode(t *testing.T) {
	a := &Agent{
		state:          &State{},
		pairingCode:    "123456",
		pairingExpires: time.Date(2026, 3, 13, 12, 0, 0, 0, time.UTC),
	}

	if !a.isPairRequestAuthorized(PairRequestPayload{
		PairingCode: "123456",
		IOSPub:      "new-ios-pub",
	}, time.Date(2026, 3, 13, 11, 59, 0, 0, time.UTC)) {
		t.Fatal("expected valid pairing code to authorize request")
	}
}

func TestIsPairRequestAuthorizedAcceptsKnownIOSKeyAfterExpiry(t *testing.T) {
	a := &Agent{
		state:          &State{PairedDevices: []PairedDevice{{ID: "known", IOSPublicKey: "known-ios-pub", PublicKeyFingerprint: "known"}}},
		pairingCode:    "123456",
		pairingExpires: time.Date(2026, 3, 13, 12, 0, 0, 0, time.UTC),
	}

	if !a.isPairRequestAuthorized(PairRequestPayload{
		PairingCode: "000000",
		IOSPub:      "known-ios-pub",
	}, time.Date(2026, 3, 13, 13, 0, 0, 0, time.UTC)) {
		t.Fatal("expected known iOS key to authorize reconnect after pairing code expiry")
	}
}

func TestIsPairRequestAuthorizedRejectsUnknownIOSKeyAfterExpiry(t *testing.T) {
	a := &Agent{
		state:          &State{PairedDevices: []PairedDevice{{ID: "known", IOSPublicKey: "known-ios-pub", PublicKeyFingerprint: "known"}}},
		pairingCode:    "123456",
		pairingExpires: time.Date(2026, 3, 13, 12, 0, 0, 0, time.UTC),
	}

	if a.isPairRequestAuthorized(PairRequestPayload{
		PairingCode: "000000",
		IOSPub:      "other-ios-pub",
	}, time.Date(2026, 3, 13, 13, 0, 0, 0, time.UTC)) {
		t.Fatal("expected unknown iOS key to be rejected after pairing code expiry")
	}
}

func TestValidatedIOSPublicKeyRejectsMalformedBase64(t *testing.T) {
	if _, err := validatedIOSPublicKey("%%%"); err == nil {
		t.Fatal("expected malformed base64 iOS key to be rejected")
	}
}

func TestValidatedIOSPublicKeyRejectsLowOrderPoint(t *testing.T) {
	if _, err := validatedIOSPublicKey("AQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="); err == nil {
		t.Fatal("expected low-order iOS key to be rejected")
	}
}

func TestHandlePairRequestResetsStaleSessionBeforeRepair(t *testing.T) {
	iosPub := base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{9}, 32))
	macPub := base64.StdEncoding.EncodeToString(bytes.Repeat([]byte{7}, 32))

	a := &Agent{
		state: &State{
			DeviceID:     "mac-device",
			MacPublicKey: macPub,
		},
		pairingCode:     "123456",
		pairingExpires:  time.Now().Add(time.Minute),
		macName:         "Test Mac",
		statePath:       t.TempDir() + "/state.json",
		crypto:          &cryptoSession{},
		macNonce:        []byte{1, 2, 3, 4},
		iosNonce:        []byte{5, 6, 7, 8},
		currentIOSPub:   "stale-ios-pub",
		currentPeerID:   "stale-peer",
		currentPeerName: "Old Phone",
		sessionReady:    true,
		maxReceivedSeq:  42,
	}

	payload, err := json.Marshal(PairRequestPayload{
		DeviceID:    "mac-device",
		PairingCode: "123456",
		IOSPub:      iosPub,
		IOSName:     "New Phone",
	})
	if err != nil {
		t.Fatalf("marshal pair request: %v", err)
	}

	a.handlePairRequest(payload)

	if a.crypto != nil {
		t.Fatal("expected stale session crypto to be cleared before repair handshake")
	}
	if len(a.iosNonce) != 0 {
		t.Fatal("expected stale iOS nonce to be cleared before repair handshake")
	}
	if a.sessionReady {
		t.Fatal("expected sessionReady to be cleared for repair handshake")
	}
	if a.maxReceivedSeq != 0 {
		t.Fatalf("expected maxReceivedSeq to reset, got %d", a.maxReceivedSeq)
	}
	if a.currentIOSPub != iosPub {
		t.Fatal("expected repaired session to track the newly paired iOS public key")
	}
	if a.currentPeerID == "" || a.currentPeerID == "stale-peer" {
		t.Fatal("expected repaired session to replace stale peer identity")
	}
	if len(a.macNonce) == 0 {
		t.Fatal("expected repair handshake to send a fresh Mac hello nonce")
	}
}

func TestRelayAPIBaseURLConvertsWebsocketSchemesForHTTPPosts(t *testing.T) {
	tests := []struct {
		name     string
		relayURL string
		want     string
	}{
		{
			name:     "secure websocket",
			relayURL: "wss://relay.example.com/connect",
			want:     "https://relay.example.com",
		},
		{
			name:     "plaintext websocket",
			relayURL: "ws://relay.example.com/connect",
			want:     "http://relay.example.com",
		},
		{
			name:     "https passthrough",
			relayURL: "https://relay.example.com/connect",
			want:     "https://relay.example.com",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			a := &Agent{relayBaseURL: tt.relayURL}
			if got := a.relayAPIBaseURL(); got != tt.want {
				t.Fatalf("relayAPIBaseURL() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestRequiresEncryptedRelayFrame(t *testing.T) {
	required := []uint8{
		protocol.TypeSessionReady,
		protocol.TypeClientState,
		protocol.TypeTabSwitch,
		protocol.TypeInput,
		protocol.TypeRemoteTelemetry,
		protocol.TypeApprovalResponse,
	}
	for _, frameType := range required {
		if !requiresEncryptedRelayFrame(frameType) {
			t.Fatalf("frame type 0x%02x should require encryption", frameType)
		}
	}

	allowedCleartext := []uint8{
		protocol.TypeHello,
		protocol.TypePairRequest,
		protocol.TypePairAccept,
		protocol.TypePairReject,
		protocol.TypePing,
	}
	for _, frameType := range allowedCleartext {
		if requiresEncryptedRelayFrame(frameType) {
			t.Fatalf("frame type 0x%02x should not require encryption", frameType)
		}
	}
}
