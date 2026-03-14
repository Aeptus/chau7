package agent

import (
	"testing"
	"time"
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
