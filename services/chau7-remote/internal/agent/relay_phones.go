package agent

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"

	"github.com/chau7/chau7-remote/internal/protocol"
)

// Per-phone relay credentials.
//
// Every phone used to hold the one iOS role credential for this Mac, so a
// phone removed on the Mac could still reach the relay. Now the Mac gives each
// phone a credential of its own, derived from the Mac role credential (which
// no phone holds), and tells the relay which phones it trusts. Once a phone
// has been removed, the relay refuses the shared credential too.

// RelayCredentialPayload is sent to a phone, encrypted, once its session is
// ready. The phone uses it for every later connection.
type RelayCredentialPayload struct {
	PhoneID     string `json:"phone_id"`
	RelaySecret string `json:"relay_secret"`
	RelayKeyID  string `json:"relay_key_id"`
}

// phoneRelayID names a phone to the relay. It is derived from the phone's
// public key, so it is stable across reconnects and says nothing else.
func phoneRelayID(iosPub string) (string, error) {
	raw, err := validatedIOSPublicKey(iosPub)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(raw)
	return "d" + base64.RawURLEncoding.EncodeToString(sum[:16]), nil
}

// pairWindowRelayID names a pairing window; the relay stops accepting its
// credential at the given unix second.
func pairWindowRelayID(expiresUnix int64) string {
	return fmt.Sprintf("p%d", expiresUnix)
}

// derivePhoneRelaySecret mirrors derivePhoneCredential in the relay's auth.js.
func derivePhoneRelaySecret(macSecret, phoneID string) (string, error) {
	key, err := base64.RawURLEncoding.Strict().DecodeString(macSecret)
	if err != nil || len(key) != 32 || !relayKeyIDPattern.MatchString(phoneID) {
		return "", errors.New("invalid phone credential parameters")
	}
	mac := hmac.New(sha256.New, key)
	_, _ = mac.Write([]byte("chau7-v4:phone:" + phoneID))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil)), nil
}

func (a *Agent) pairedPhoneRelayIDs() []string {
	a.stateMu.Lock()
	defer a.stateMu.Unlock()
	ids := make([]string, 0, len(a.state.PairedDevices))
	for _, device := range a.state.PairedDevices {
		if id, err := phoneRelayID(device.IOSPublicKey); err == nil {
			ids = append(ids, id)
		}
	}
	return ids
}

// syncRelayPhones tells the relay which phones this Mac trusts, and reports
// whether the relay enforces the list. A relay that predates the feature
// answers 404; phones then keep using the shared credential.
func (a *Agent) syncRelayPhones(ctx context.Context) bool {
	supported, err := a.putRelayPhones(ctx, a.pairedPhoneRelayIDs())
	if err != nil {
		// Unknown: keep what the last answer said rather than flip on a blip.
		log.Printf("relay phones: %v", err)
		return a.phoneCredentialsSupported.Load()
	}
	if a.phoneCredentialsSupported.Swap(supported) != supported {
		// The pairing QR gains or loses its pairing-window credential.
		a.sendPairingInfo()
	}
	return supported
}

func (a *Agent) putRelayPhones(ctx context.Context, phones []string) (bool, error) {
	body, err := json.Marshal(map[string][]string{"phones": phones})
	if err != nil {
		return false, err
	}
	authorization, err := a.relayAuthorization("phones")
	if err != nil {
		return false, err
	}
	ctx, cancel := context.WithTimeout(ctx, relayRequestTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, a.relayAPIBaseURL()+"/phones/"+a.state.DeviceID, bytes.NewReader(body))
	if err != nil {
		return false, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", authorization)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return false, err
	}
	defer func() { _ = resp.Body.Close() }()
	switch resp.StatusCode {
	case http.StatusOK:
		return true, nil
	case http.StatusNotFound, http.StatusMethodNotAllowed:
		return false, nil
	default:
		detail, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
		return false, fmt.Errorf("relay http /phones: %s %s", resp.Status, strings.TrimSpace(string(detail)))
	}
}

// issuePhoneCredential gives the phone in the current session its own relay
// credential. The relay must know the phone first, or the credential would be
// refused on its first use.
func (a *Agent) issuePhoneCredential(ctx context.Context) {
	if !a.syncRelayPhones(ctx) {
		return
	}
	a.sessionMu.Lock()
	iosPub, ready := a.currentIOSPub, a.sessionReady
	a.sessionMu.Unlock()
	if !ready || iosPub == "" {
		return
	}
	a.stateMu.Lock()
	trusted := a.state.FindPairedDeviceByPublicKey(iosPub) != nil
	a.stateMu.Unlock()
	if !trusted {
		return
	}
	credentials, err := a.currentRelayCredentials()
	if err != nil {
		return
	}
	phoneID, err := phoneRelayID(iosPub)
	if err != nil {
		return
	}
	secret, err := derivePhoneRelaySecret(credentials.MacSecret, phoneID)
	if err != nil {
		return
	}
	payload, err := json.Marshal(RelayCredentialPayload{PhoneID: phoneID, RelaySecret: secret, RelayKeyID: credentials.KeyID})
	if err != nil {
		return
	}
	a.sendEncryptedToRelay(ctx, &protocol.Frame{Version: 1, Type: protocol.TypeRelayCredential, Payload: payload})
}
