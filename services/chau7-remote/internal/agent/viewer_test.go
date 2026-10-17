package agent

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/chau7/chau7-remote/internal/protocol"
)

func mustJSON(t *testing.T, v any) []byte {
	t.Helper()
	data, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return data
}

func decision(t *testing.T, frame *protocol.Frame) ViewerDecisionPayload {
	t.Helper()
	if frame.Type != protocol.TypeViewerDecision {
		t.Fatalf("expected viewer_decision, got 0x%02x", frame.Type)
	}
	var d ViewerDecisionPayload
	if err := json.Unmarshal(frame.Payload, &d); err != nil {
		t.Fatalf("decision payload: %v", err)
	}
	return d
}

func sharingHub(t *testing.T, code string, limit int) *viewerHub {
	t.Helper()
	h := newViewerHub()
	h.share(mustJSON(t, ViewerSharePayload{ShareCode: &code, MaxViewers: limit}))
	return h
}

func TestViewerJoinRejectedWhenNotSharing(t *testing.T) {
	h := newViewerHub()
	out := h.join(mustJSON(t, ViewerJoinPayload{ViewerID: "v1", ShareCode: "abcd1234"}))
	if len(out.toIPC) != 0 || len(out.toRelay) != 1 {
		t.Fatalf("expected one rejection to the relay, got %+v", out)
	}
	if d := decision(t, out.toRelay[0]); d.Approved || d.Reason != "not_sharing" {
		t.Fatalf("unexpected decision %+v", d)
	}
}

func TestViewerJoinWithWrongCodeNeverReachesTheApp(t *testing.T) {
	h := sharingHub(t, "abcd1234", 2)
	out := h.join(mustJSON(t, ViewerJoinPayload{ViewerID: "v1", ShareCode: "zzzz0000"}))
	if len(out.toIPC) != 0 {
		t.Fatal("a wrong code must not reach the app")
	}
	if d := decision(t, out.toRelay[0]); d.Reason != "invalid_code" {
		t.Fatalf("unexpected decision %+v", d)
	}
}

func TestViewerApprovalFlowAndLiveCopies(t *testing.T) {
	h := sharingHub(t, "ABCD1234", 2)
	out := h.join(mustJSON(t, ViewerJoinPayload{ViewerID: "v1", Name: "Ann", ShareCode: "abcd1234"}))
	if len(out.toIPC) != 1 || out.toIPC[0].Type != protocol.TypeViewerJoin {
		t.Fatalf("expected the join to go to the app, got %+v", out)
	}
	// Nothing is copied before the owner approves.
	live := &protocol.Frame{Version: 1, Type: protocol.TypeOutput, TabID: 3, Payload: []byte("ls\n")}
	if copies := h.liveCopies(live); len(copies) != 0 {
		t.Fatal("pending viewers must not get output")
	}
	out = h.decide(mustJSON(t, ViewerDecisionPayload{ViewerID: "v1", Approved: true}))
	if d := decision(t, out.toRelay[0]); !d.Approved {
		t.Fatalf("expected approval, got %+v", d)
	}
	copies := h.liveCopies(live)
	if len(copies) != 1 || copies[0].Type != protocol.TypeViewerOutput {
		t.Fatalf("expected one viewer_output, got %+v", copies)
	}
	id, inner, err := DecodeViewerOutput(copies[0].Payload)
	if err != nil || id != "v1" || inner.Type != protocol.TypeOutput || string(inner.Payload) != "ls\n" {
		t.Fatalf("bad viewer_output: id=%q inner=%+v err=%v", id, inner, err)
	}
	// Input and approvals are never copied.
	if copies := h.liveCopies(&protocol.Frame{Type: protocol.TypeApprovalRequest}); len(copies) != 0 {
		t.Fatal("approval requests must not reach viewers")
	}
}

func TestViewerMaximumAndDenial(t *testing.T) {
	h := sharingHub(t, "abcd1234", 1)
	h.join(mustJSON(t, ViewerJoinPayload{ViewerID: "v1", ShareCode: "abcd1234"}))
	h.decide(mustJSON(t, ViewerDecisionPayload{ViewerID: "v1", Approved: true}))
	out := h.join(mustJSON(t, ViewerJoinPayload{ViewerID: "v2", ShareCode: "abcd1234"}))
	if d := decision(t, out.toRelay[0]); d.Approved || d.Reason != "max_viewers" {
		t.Fatalf("expected max_viewers, got %+v", d)
	}
	h2 := sharingHub(t, "abcd1234", 3)
	h2.join(mustJSON(t, ViewerJoinPayload{ViewerID: "v3", ShareCode: "abcd1234"}))
	out = h2.decide(mustJSON(t, ViewerDecisionPayload{ViewerID: "v3", Approved: false}))
	if d := decision(t, out.toRelay[0]); d.Approved || d.Reason != "denied" {
		t.Fatalf("expected denial, got %+v", d)
	}
	// A decision for an unknown viewer does nothing.
	if out := h2.decide(mustJSON(t, ViewerDecisionPayload{ViewerID: "nobody", Approved: true})); len(out.toRelay) != 0 {
		t.Fatal("unknown viewer decision must be ignored")
	}
}

func TestStopSharingEndsEveryViewing(t *testing.T) {
	h := sharingHub(t, "abcd1234", 3)
	h.join(mustJSON(t, ViewerJoinPayload{ViewerID: "v1", ShareCode: "abcd1234"}))
	h.decide(mustJSON(t, ViewerDecisionPayload{ViewerID: "v1", Approved: true}))
	h.join(mustJSON(t, ViewerJoinPayload{ViewerID: "v2", ShareCode: "abcd1234"}))
	out := h.share(mustJSON(t, ViewerSharePayload{ShareCode: nil, MaxViewers: 3}))
	if len(out.toRelay) != 3 {
		t.Fatalf("expected a leave, a rejection and the share, got %d frames", len(out.toRelay))
	}
	last := out.toRelay[2]
	var share ViewerSharePayload
	if err := json.Unmarshal(last.Payload, &share); err != nil || last.Type != protocol.TypeViewerShare || share.ShareCode != nil {
		t.Fatalf("expected viewer_share with no code last, got %+v", last)
	}
	if copies := h.liveCopies(&protocol.Frame{Type: protocol.TypeOutput}); len(copies) != 0 {
		t.Fatal("no viewer may remain after sharing stops")
	}
}

func TestViewerLeaveBothWays(t *testing.T) {
	h := sharingHub(t, "abcd1234", 3)
	h.join(mustJSON(t, ViewerJoinPayload{ViewerID: "v1", ShareCode: "abcd1234"}))
	h.decide(mustJSON(t, ViewerDecisionPayload{ViewerID: "v1", Approved: true}))
	out := h.leaveFromRelay(mustJSON(t, ViewerLeavePayload{ViewerID: "v1"}))
	if len(out.toIPC) != 1 || out.toIPC[0].Type != protocol.TypeViewerLeave {
		t.Fatalf("expected the app to hear the leave, got %+v", out)
	}
	h.join(mustJSON(t, ViewerJoinPayload{ViewerID: "v2", ShareCode: "abcd1234"}))
	h.decide(mustJSON(t, ViewerDecisionPayload{ViewerID: "v2", Approved: true}))
	out = h.leaveFromApp(mustJSON(t, ViewerLeavePayload{ViewerID: "v2"}))
	if len(out.toRelay) != 1 || out.toRelay[0].Type != protocol.TypeViewerLeave {
		t.Fatalf("expected the relay to hear the leave, got %+v", out)
	}
	if copies := h.liveCopies(&protocol.Frame{Type: protocol.TypeOutput}); len(copies) != 0 {
		t.Fatal("viewers that left must not get output")
	}
}

func TestAgentRoutesViewerFramesWithoutConnections(t *testing.T) {
	// No socket and no relay: the handlers must not panic.
	a := &Agent{state: &State{}}
	code := "abcd1234"
	a.handleIPCFrame(context.Background(), &protocol.Frame{Version: 1, Type: protocol.TypeViewerShare, Payload: mustJSON(t, ViewerSharePayload{ShareCode: &code, MaxViewers: 2})})
	a.handleRelayFrame(context.Background(), &protocol.Frame{Version: 1, Type: protocol.TypeViewerJoin, Payload: mustJSON(t, ViewerJoinPayload{ViewerID: "v1", ShareCode: code})})
	if _, ok := a.viewerHub().pending["v1"]; !ok {
		t.Fatal("expected the join to wait for the app")
	}
	a.handleIPCFrame(context.Background(), &protocol.Frame{Version: 1, Type: protocol.TypeViewerDecision, Payload: mustJSON(t, ViewerDecisionPayload{ViewerID: "v1", Approved: true})})
	if _, ok := a.viewerHub().approved["v1"]; !ok {
		t.Fatal("expected the viewer to be approved")
	}
	a.handleIPCFrame(context.Background(), &protocol.Frame{Version: 1, Type: protocol.TypeOutput, Payload: []byte("x")})
}

func TestShareIsSentToTheRelayWhenItChanges(t *testing.T) {
	h := newViewerHub()
	if h.relayConnected() != nil {
		t.Fatal("nothing to register while not sharing")
	}
	code := "ABCD1234"
	out := h.share(mustJSON(t, ViewerSharePayload{ShareCode: &code, MaxViewers: 2}))
	if len(out.toRelay) != 1 || out.toRelay[0].Type != protocol.TypeViewerShare {
		t.Fatalf("expected viewer_share to the relay, got %+v", out)
	}
	var share ViewerSharePayload
	if err := json.Unmarshal(out.toRelay[0].Payload, &share); err != nil || share.ShareCode == nil || *share.ShareCode != "abcd1234" {
		t.Fatalf("expected the normalized code, got %s", out.toRelay[0].Payload)
	}
	// The same code again (only the maximum changes) is not resent.
	if out := h.share(mustJSON(t, ViewerSharePayload{ShareCode: &code, MaxViewers: 3})); len(out.toRelay) != 0 {
		t.Fatalf("unchanged code must not be resent, got %+v", out)
	}
	if frame := h.relayConnected(); frame == nil || frame.Type != protocol.TypeViewerShare {
		t.Fatal("expected the share to be registered again after a reconnect")
	}
}

func TestRelayLostEndsEveryViewing(t *testing.T) {
	h := sharingHub(t, "abcd1234", 3)
	h.join(mustJSON(t, ViewerJoinPayload{ViewerID: "v1", ShareCode: "abcd1234"}))
	h.decide(mustJSON(t, ViewerDecisionPayload{ViewerID: "v1", Approved: true}))
	h.join(mustJSON(t, ViewerJoinPayload{ViewerID: "v2", ShareCode: "abcd1234"}))
	out := h.relayLost()
	if len(out.toIPC) != 2 || len(out.toRelay) != 0 {
		t.Fatalf("expected two leaves to the app, got %+v", out)
	}
	if copies := h.liveCopies(&protocol.Frame{Type: protocol.TypeOutput}); len(copies) != 0 {
		t.Fatal("no viewer may remain after the relay is lost")
	}
	if h.relayConnected() == nil {
		t.Fatal("the share itself survives a lost relay")
	}
}
