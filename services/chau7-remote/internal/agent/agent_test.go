package agent

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/chau7/chau7-remote/internal/protocol"
)

func TestAnnounceIPCConnectionReplaysExistingSessionStatus(t *testing.T) {
	for _, tt := range []struct {
		name         string
		sessionReady bool
		wantStatus   string
	}{
		{name: "ready session", sessionReady: true, wantStatus: "ready"},
		{name: "disconnected session", sessionReady: false, wantStatus: "disconnected"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			socketPath := fmt.Sprintf("/tmp/ch7-ipc-%d.sock", time.Now().UnixNano())
			t.Cleanup(func() { _ = os.Remove(socketPath) })
			listener, err := net.ListenUnix("unix", &net.UnixAddr{
				Name: socketPath,
				Net:  "unix",
			})
			if err != nil {
				t.Fatalf("listen unix: %v", err)
			}
			defer listener.Close()

			accepted := make(chan *net.UnixConn, 1)
			acceptErr := make(chan error, 1)
			go func() {
				conn, err := listener.AcceptUnix()
				if err != nil {
					acceptErr <- err
					return
				}
				accepted <- conn
			}()

			client, err := net.DialUnix("unix", nil, listener.Addr().(*net.UnixAddr))
			if err != nil {
				t.Fatalf("dial unix: %v", err)
			}
			defer client.Close()

			var server *net.UnixConn
			select {
			case server = <-accepted:
			case err := <-acceptErr:
				t.Fatalf("accept unix: %v", err)
			case <-time.After(time.Second):
				t.Fatal("timed out accepting unix connection")
			}
			defer server.Close()

			a := &Agent{
				state:        &State{DeviceID: "mac-device"},
				ipcConn:      client,
				sessionReady: tt.sessionReady,
			}
			a.announceIPCConnection()

			reader := bufio.NewReader(server)
			pairingFrame, err := readIPCFrame(reader)
			if err != nil {
				t.Fatalf("read pairing frame: %v", err)
			}
			if pairingFrame.Type != protocol.TypePairingInfo {
				t.Fatalf("first frame type = 0x%02x, want pairing info", pairingFrame.Type)
			}

			statusFrame, err := readIPCFrame(reader)
			if err != nil {
				t.Fatalf("read session status frame: %v", err)
			}
			if statusFrame.Type != protocol.TypeSessionStatus {
				t.Fatalf("second frame type = 0x%02x, want session status", statusFrame.Type)
			}
			var status SessionStatusPayload
			if err := json.Unmarshal(statusFrame.Payload, &status); err != nil {
				t.Fatalf("decode session status: %v", err)
			}
			if status.Status != tt.wantStatus {
				t.Fatalf("session status = %q, want %q", status.Status, tt.wantStatus)
			}
		})
	}
}

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
			relayURL: "wss://relay.chau7.sh/connect",
			want:     "https://relay.chau7.sh",
		},
		{
			name:     "plaintext websocket",
			relayURL: "ws://relay.chau7.sh/connect",
			want:     "http://relay.chau7.sh",
		},
		{
			name:     "https passthrough",
			relayURL: "https://relay.chau7.sh/connect",
			want:     "https://relay.chau7.sh",
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
		protocol.TypeKeyInput,
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

func TestEncryptRelayFramePreservesPlaintextInput(t *testing.T) {
	crypto, err := newCryptoSession(
		bytes.Repeat([]byte{0x11}, 32),
		bytes.Repeat([]byte{0x22}, 16),
		bytes.Repeat([]byte{0x33}, 16),
	)
	if err != nil {
		t.Fatalf("new crypto session: %v", err)
	}

	payload := []byte(`{"prompts":[{"id":"prompt-1"}]}`)
	frame := &protocol.Frame{
		Version: 1,
		Type:    protocol.TypeInteractivePromptList,
		Seq:     42,
		Payload: append([]byte(nil), payload...),
	}

	encrypted := encryptRelayFrame(frame, crypto)

	if frame.Flags != 0 {
		t.Fatalf("plaintext frame flags mutated to 0x%02x", frame.Flags)
	}
	if !bytes.Equal(frame.Payload, payload) {
		t.Fatal("plaintext frame payload was mutated")
	}
	if encrypted == frame {
		t.Fatal("expected a distinct encrypted frame")
	}
	if encrypted.Flags&protocol.FlagEncrypted == 0 {
		t.Fatal("encrypted frame is missing encrypted flag")
	}
	if bytes.Equal(encrypted.Payload, payload) {
		t.Fatal("encrypted payload unexpectedly matches plaintext")
	}

	nonce := makeNonce(crypto.sendNoncePrefix, encrypted.Seq)
	header := encrypted.HeaderBytes(uint32(len(encrypted.Payload)))
	decrypted, err := crypto.aead.Open(nil, nonce, encrypted.Payload, header)
	if err != nil {
		t.Fatalf("decrypt encrypted frame: %v", err)
	}
	if !bytes.Equal(decrypted, payload) {
		t.Fatalf("decrypted payload = %q, want %q", decrypted, payload)
	}
}

func TestUpdatePendingApprovalSyncsRelayState(t *testing.T) {
	var got PendingStatePayload
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/pending/device-1" {
			t.Fatalf("unexpected path: %s", r.URL.Path)
		}
		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Fatalf("read body: %v", err)
		}
		if err := json.Unmarshal(body, &got); err != nil {
			t.Fatalf("unmarshal body: %v", err)
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	a := &Agent{
		relayBaseURL:     server.URL + "/connect",
		state:            &State{DeviceID: "device-1"},
		pendingApprovals: map[string]ApprovalNotificationPayload{},
		pendingPrompts:   map[string]RemoteInteractivePrompt{},
	}

	payload, err := json.Marshal(ApprovalNotificationPayload{
		RequestID:      "req-1",
		Command:        "git push",
		FlaggedCommand: "git push --force",
		TabTitle:       "Claude",
		ToolName:       "Claude Code",
	})
	if err != nil {
		t.Fatalf("marshal approval payload: %v", err)
	}

	a.updatePendingApproval(payload)

	if len(got.Approvals) != 1 {
		t.Fatalf("expected 1 approval, got %d", len(got.Approvals))
	}
	if got.Approvals[0].RequestID != "req-1" {
		t.Fatalf("unexpected request id: %s", got.Approvals[0].RequestID)
	}
}

func TestFailedPushStaysEligibleForRetry(t *testing.T) {
	attempts := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.URL.Path, "/push/notify/") {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		attempts++
		if attempts == 1 {
			// e.g. the relay's new fail-loud response when APNs is unconfigured.
			w.WriteHeader(http.StatusBadGateway)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	a := &Agent{
		relayBaseURL: server.URL + "/connect",
		state:        &State{DeviceID: "device-1"},
		// Default state is push-eligible (background) — no clientState needed.
		currentClientAppState: "background",
		notifiedApprovalIDs:   map[string]time.Time{},
		notifiedPromptIDs:     map[string]time.Time{},
		notifiedEventKeys:     map[string]time.Time{},
	}

	approval := ApprovalNotificationPayload{
		RequestID:      "req-1",
		Command:        "git push",
		FlaggedCommand: "git push",
	}

	a.emitApprovalPush(approval)
	if attempts != 1 {
		t.Fatalf("expected first push attempt, got %d", attempts)
	}
	// The failed attempt must not poison the dedup set: a flush retries it.
	a.emitApprovalPush(approval)
	if attempts != 2 {
		t.Fatalf("failed push must stay eligible for retry, attempts=%d", attempts)
	}
	// Once delivered, further emits dedup.
	a.emitApprovalPush(approval)
	if attempts != 2 {
		t.Fatalf("delivered push must dedup, attempts=%d", attempts)
	}
}

func TestStateVersionAdoptsMacSpineSeq(t *testing.T) {
	var got PendingStatePayload
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Fatalf("read body: %v", err)
		}
		if err := json.Unmarshal(body, &got); err != nil {
			t.Fatalf("unmarshal body: %v", err)
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	a := &Agent{
		relayBaseURL:     server.URL + "/connect",
		state:            &State{DeviceID: "device-1"},
		pendingApprovals: map[string]ApprovalNotificationPayload{},
		pendingPrompts:   map[string]RemoteInteractivePrompt{},
	}

	// A Mac payload carrying spine_seq: state_version adopts it.
	seq := uint64(4200)
	payload, err := json.Marshal(ApprovalNotificationPayload{
		RequestID:      "req-1",
		Command:        "git push",
		FlaggedCommand: "git push",
		SpineSeq:       &seq,
	})
	if err != nil {
		t.Fatalf("marshal approval payload: %v", err)
	}
	a.updatePendingApproval(payload)
	if got.StateVersion != 4200 {
		t.Fatalf("state_version should adopt the Mac spine seq, got %d", got.StateVersion)
	}

	// A seq-less sync (e.g. an iOS-triggered clear) must still move the
	// version strictly forward.
	a.clearPendingApproval("req-1")
	if got.StateVersion != 4201 {
		t.Fatalf("seq-less sync must fall back to increment, got %d", got.StateVersion)
	}

	// A stale/lower spine seq never moves the version backwards.
	stale := uint64(1000)
	payload, err = json.Marshal(ApprovalNotificationPayload{
		RequestID:      "req-2",
		Command:        "ls",
		FlaggedCommand: "ls",
		SpineSeq:       &stale,
	})
	if err != nil {
		t.Fatalf("marshal stale payload: %v", err)
	}
	a.updatePendingApproval(payload)
	if got.StateVersion != 4202 {
		t.Fatalf("stale spine seq must not regress the version, got %d", got.StateVersion)
	}
}

func TestClearPendingApprovalRemovesItFromRelayState(t *testing.T) {
	var got PendingStatePayload
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Fatalf("read body: %v", err)
		}
		if err := json.Unmarshal(body, &got); err != nil {
			t.Fatalf("unmarshal body: %v", err)
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	a := &Agent{
		relayBaseURL: server.URL + "/connect",
		state:        &State{DeviceID: "device-1"},
		pendingApprovals: map[string]ApprovalNotificationPayload{
			"req-1": {RequestID: "req-1", Command: "git push"},
		},
		pendingPrompts: map[string]RemoteInteractivePrompt{},
	}

	a.clearPendingApproval("req-1")

	if len(got.Approvals) != 0 {
		t.Fatalf("expected cleared approvals, got %d", len(got.Approvals))
	}
}
