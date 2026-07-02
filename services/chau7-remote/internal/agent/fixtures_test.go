package agent

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// TestWireFixtureRoundTrips proves the Go payload structs stay in sync with
// the language-neutral golden fixtures under docs/fixtures/, which are also
// round-trip-tested by the Swift shared types in
// apps/chau7-macos/Tests/Chau7Tests/Remote/RemoteWirePayloadFixtureTests.swift.
// A schema change that breaks either implementation fails one of the suites
// instead of shipping silent drift.
func TestWireFixtureRoundTrips(t *testing.T) {
	cases := []struct {
		fixture string
		value   any
	}{
		{"approval_request.json", &ApprovalNotificationPayload{}},
		{"approval_response.json", &ApprovalResponsePayload{}},
		{"client_state.json", &RemoteClientStatePayload{}},
		{"tab_switch.json", &TabSwitchPayload{}},
		{"pending_state.json", &PendingStatePayload{}},
		{"hello.json", &HelloPayload{}},
		{"pair_request.json", &PairRequestPayload{}},
		{"pair_accept.json", &PairAcceptPayload{}},
		{"session_ready.json", &SessionReadyPayload{}},
		{"pairing_info.json", &PairingInfoPayload{}},
		{"notification_event.json", &NotificationEventPayload{}},
	}

	for _, tc := range cases {
		t.Run(tc.fixture, func(t *testing.T) {
			data, err := os.ReadFile(filepath.Join("..", "..", "docs", "fixtures", tc.fixture))
			if err != nil {
				t.Fatalf("read fixture: %v", err)
			}

			dec := json.NewDecoder(bytes.NewReader(data))
			dec.DisallowUnknownFields()
			if err := dec.Decode(tc.value); err != nil {
				t.Fatalf("decode into %T: %v (schema drifted from fixture?)", tc.value, err)
			}

			reencoded, err := json.Marshal(tc.value)
			if err != nil {
				t.Fatalf("re-encode: %v", err)
			}

			var original, roundTripped map[string]any
			if err := json.Unmarshal(data, &original); err != nil {
				t.Fatalf("unmarshal original: %v", err)
			}
			if err := json.Unmarshal(reencoded, &roundTripped); err != nil {
				t.Fatalf("unmarshal re-encoded: %v", err)
			}
			if !reflect.DeepEqual(original, roundTripped) {
				t.Fatalf("JSON round-trip drifted for %s:\noriginal:    %v\nround-trip:  %v", tc.fixture, original, roundTripped)
			}
		})
	}
}
