package viewer

import (
	"bytes"
	"encoding/json"
	"errors"
	"testing"

	"github.com/chau7/chau7-remote/internal/protocol"
)

func jsonFrame(t *testing.T, frameType uint8, v any) []byte {
	t.Helper()
	data, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	frame := protocol.Frame{Version: 1, Type: frameType, Payload: data}
	return frame.Encode()
}

func outputFor(id string, inner protocol.Frame) []byte {
	encoded := inner.Encode()
	payload := append([]byte{byte(len(id))}, id...) //nolint:gosec // test ids are short
	payload = append(payload, encoded...)
	frame := protocol.Frame{Version: 1, Type: protocol.TypeViewerOutput, Payload: payload}
	return frame.Encode()
}

func TestViewURL(t *testing.T) {
	cases := map[string]string{
		"wss://relay.example.com/connect":  "wss://relay.example.com/view/abcd1234",
		"wss://relay.example.com/connect/": "wss://relay.example.com/view/abcd1234",
		"ws://127.0.0.1:8787":              "ws://127.0.0.1:8787/view/abcd1234",
	}
	for in, want := range cases {
		if got := ViewURL(in, " ABCD1234 "); got != want {
			t.Errorf("ViewURL(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestJoinFrame(t *testing.T) {
	frame, err := protocol.DecodeFrame(JoinFrame("v1", "Ann", "ABCD1234"))
	if err != nil || frame.Type != protocol.TypeViewerJoin {
		t.Fatalf("bad join frame: %+v %v", frame, err)
	}
	var join joinPayload
	if err := json.Unmarshal(frame.Payload, &join); err != nil || join != (joinPayload{"v1", "Ann", "abcd1234"}) {
		t.Fatalf("bad join payload: %s", frame.Payload)
	}
}

func TestSessionShowsOutputOnlyAfterApproval(t *testing.T) {
	var out, logs bytes.Buffer
	s := &Session{ViewerID: "v1", Output: &out, Log: &logs}
	hello := outputFor("v1", protocol.Frame{Version: 1, Type: protocol.TypeOutput, Payload: []byte("hello")})
	if err := s.Handle(hello); err != nil || out.Len() != 0 {
		t.Fatal("output before approval must be ignored")
	}
	if err := s.Handle(jsonFrame(t, protocol.TypeViewerDecision, decisionPayload{ViewerID: "v1", Approved: true})); err != nil || !s.Approved {
		t.Fatalf("expected approval, got %v", err)
	}
	_ = s.Handle(hello)
	_ = s.Handle(outputFor("v2", protocol.Frame{Version: 1, Type: protocol.TypeOutput, Payload: []byte("not mine")}))
	_ = s.Handle(outputFor("v1", protocol.Frame{Version: 1, Type: protocol.TypeSnapshot, Payload: []byte(" world")}))
	if out.String() != "hello world" {
		t.Fatalf("unexpected output %q", out.String())
	}
	if err := s.Handle(jsonFrame(t, protocol.TypeViewerLeave, map[string]string{"viewer_id": "v1"})); !errors.Is(err, ErrEnded) {
		t.Fatalf("expected ErrEnded, got %v", err)
	}
}

func TestSessionReportsDenial(t *testing.T) {
	var out, logs bytes.Buffer
	s := &Session{ViewerID: "v1", Output: &out, Log: &logs}
	err := s.Handle(jsonFrame(t, protocol.TypeViewerDecision, decisionPayload{ViewerID: "v1", Approved: false, Reason: "denied"}))
	var denied ErrDenied
	if !errors.As(err, &denied) || denied.Reason != "denied" {
		t.Fatalf("expected ErrDenied{denied}, got %v", err)
	}
}
