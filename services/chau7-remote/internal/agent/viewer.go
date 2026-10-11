package agent

// Read-only viewers (docs/remote-control/VIEWER-PROTOCOL.md).
//
// The app (Chau7 Next) shares a link with an 8 character code and sends the
// code with viewer_share. A viewer reaches the agent through the relay with
// viewer_join; a join with a wrong code, while nothing is shared, or over the
// maximum is rejected here and never reaches the app. A valid join goes to
// the app, which approves or denies it (viewer_decision). Approved viewers
// get a copy of the live frames the app sends (tab list, output, snapshots)
// wrapped in viewer_output. Viewers can never send input: only joins and
// leaves are read from them.

import (
	"encoding/json"
	"strings"
	"sync"

	"github.com/chau7/chau7-remote/internal/protocol"
)

const (
	defaultMaxViewers = 5
	maxViewersLimit   = 10
	maxViewerIDLength = 255
)

type ViewerSharePayload struct {
	ShareCode  *string `json:"share_code"`
	MaxViewers int     `json:"max_viewers"`
}

type ViewerJoinPayload struct {
	ViewerID  string `json:"viewer_id"`
	Name      string `json:"name"`
	ShareCode string `json:"share_code"`
}

type ViewerDecisionPayload struct {
	ViewerID string `json:"viewer_id"`
	Approved bool   `json:"approved"`
	Reason   string `json:"reason,omitempty"`
}

type ViewerLeavePayload struct {
	ViewerID string `json:"viewer_id"`
}

// viewerFrames are frames to send: to the relay (viewers) and to the app.
type viewerFrames struct {
	toRelay []*protocol.Frame
	toIPC   []*protocol.Frame
}

type viewerHub struct {
	mu         sync.Mutex
	shareCode  string
	maxViewers int
	pending    map[string]string // id -> name
	approved   map[string]string
}

func newViewerHub() *viewerHub {
	return &viewerHub{
		maxViewers: defaultMaxViewers,
		pending:    map[string]string{},
		approved:   map[string]string{},
	}
}

func jsonFrame(frameType uint8, payload any) *protocol.Frame {
	data, _ := json.Marshal(payload)
	return &protocol.Frame{Version: 1, Type: frameType, Payload: data}
}

func decisionFrame(id string, approved bool, reason string) *protocol.Frame {
	return jsonFrame(protocol.TypeViewerDecision, ViewerDecisionPayload{ViewerID: id, Approved: approved, Reason: reason})
}

func leaveFrame(id string) *protocol.Frame {
	return jsonFrame(protocol.TypeViewerLeave, ViewerLeavePayload{ViewerID: id})
}

// share handles viewer_share from the app. Stopping (no code) or changing
// the code ends every viewing.
func (h *viewerHub) share(payload []byte) viewerFrames {
	var share ViewerSharePayload
	if err := json.Unmarshal(payload, &share); err != nil {
		return viewerFrames{}
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	code := ""
	if share.ShareCode != nil {
		code = strings.ToLower(strings.TrimSpace(*share.ShareCode))
	}
	limit := share.MaxViewers
	if limit <= 0 {
		limit = defaultMaxViewers
	}
	if limit > maxViewersLimit {
		limit = maxViewersLimit
	}
	h.maxViewers = limit
	var out viewerFrames
	if code != h.shareCode {
		for id := range h.pending {
			out.toRelay = append(out.toRelay, decisionFrame(id, false, "share_ended"))
		}
		for id := range h.approved {
			out.toRelay = append(out.toRelay, leaveFrame(id))
		}
		h.pending = map[string]string{}
		h.approved = map[string]string{}
		h.shareCode = code
		// Last, so the relay routes the endings above before it drops the
		// viewers of the old code.
		out.toRelay = append(out.toRelay, h.shareFrameLocked())
	}
	return out
}

// shareFrameLocked is the viewer_share the relay needs to route viewers of
// the current code to this Mac (share_code null when nothing is shared).
func (h *viewerHub) shareFrameLocked() *protocol.Frame {
	var code *string
	if h.shareCode != "" {
		shared := h.shareCode
		code = &shared
	}
	return jsonFrame(protocol.TypeViewerShare, ViewerSharePayload{ShareCode: code, MaxViewers: h.maxViewers})
}

// relayConnected returns the viewer_share to send after (re)connecting to
// the relay, or nil when nothing is shared.
func (h *viewerHub) relayConnected() *protocol.Frame {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.shareCode == "" {
		return nil
	}
	return h.shareFrameLocked()
}

// relayLost handles a lost relay connection: the relay closed every viewer
// socket, so every viewing ends and the app hears a leave for each viewer.
func (h *viewerHub) relayLost() viewerFrames {
	h.mu.Lock()
	defer h.mu.Unlock()
	var out viewerFrames
	for id := range h.pending {
		out.toIPC = append(out.toIPC, leaveFrame(id))
	}
	for id := range h.approved {
		out.toIPC = append(out.toIPC, leaveFrame(id))
	}
	h.pending = map[string]string{}
	h.approved = map[string]string{}
	return out
}

// join handles viewer_join from the relay.
func (h *viewerHub) join(payload []byte) viewerFrames {
	var join ViewerJoinPayload
	if err := json.Unmarshal(payload, &join); err != nil {
		return viewerFrames{}
	}
	id := strings.TrimSpace(join.ViewerID)
	if id == "" || len(id) > maxViewerIDLength {
		return viewerFrames{}
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	reject := func(reason string) viewerFrames {
		return viewerFrames{toRelay: []*protocol.Frame{decisionFrame(id, false, reason)}}
	}
	if h.shareCode == "" {
		return reject("not_sharing")
	}
	if strings.ToLower(strings.TrimSpace(join.ShareCode)) != h.shareCode {
		return reject("invalid_code")
	}
	if _, ok := h.approved[id]; ok {
		return viewerFrames{toRelay: []*protocol.Frame{decisionFrame(id, true, "")}}
	}
	if len(h.approved) >= h.maxViewers {
		return reject("max_viewers")
	}
	h.pending[id] = join.Name
	clean := ViewerJoinPayload{ViewerID: id, Name: join.Name, ShareCode: h.shareCode}
	return viewerFrames{toIPC: []*protocol.Frame{jsonFrame(protocol.TypeViewerJoin, clean)}}
}

// decide handles viewer_decision from the app.
func (h *viewerHub) decide(payload []byte) viewerFrames {
	var decision ViewerDecisionPayload
	if err := json.Unmarshal(payload, &decision); err != nil {
		return viewerFrames{}
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	name, waiting := h.pending[decision.ViewerID]
	if !waiting {
		return viewerFrames{}
	}
	delete(h.pending, decision.ViewerID)
	if decision.Approved && len(h.approved) < h.maxViewers {
		h.approved[decision.ViewerID] = name
		return viewerFrames{toRelay: []*protocol.Frame{decisionFrame(decision.ViewerID, true, "")}}
	}
	reason := decision.Reason
	if decision.Approved {
		reason = "max_viewers"
	}
	if reason == "" {
		reason = "denied"
	}
	return viewerFrames{toRelay: []*protocol.Frame{decisionFrame(decision.ViewerID, false, reason)}}
}

// leaveFromApp handles viewer_leave from the app (disconnect, revoke).
func (h *viewerHub) leaveFromApp(payload []byte) viewerFrames {
	var leave ViewerLeavePayload
	if err := json.Unmarshal(payload, &leave); err != nil {
		return viewerFrames{}
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	_, approved := h.approved[leave.ViewerID]
	_, pending := h.pending[leave.ViewerID]
	if !approved && !pending {
		return viewerFrames{}
	}
	delete(h.approved, leave.ViewerID)
	delete(h.pending, leave.ViewerID)
	return viewerFrames{toRelay: []*protocol.Frame{leaveFrame(leave.ViewerID)}}
}

// leaveFromRelay handles viewer_leave from the relay (the viewer closed).
func (h *viewerHub) leaveFromRelay(payload []byte) viewerFrames {
	var leave ViewerLeavePayload
	if err := json.Unmarshal(payload, &leave); err != nil {
		return viewerFrames{}
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	_, approved := h.approved[leave.ViewerID]
	_, pending := h.pending[leave.ViewerID]
	if !approved && !pending {
		return viewerFrames{}
	}
	delete(h.approved, leave.ViewerID)
	delete(h.pending, leave.ViewerID)
	return viewerFrames{toIPC: []*protocol.Frame{leaveFrame(leave.ViewerID)}}
}

// isViewerLiveFrame reports frame types copied to approved viewers.
func isViewerLiveFrame(frameType uint8) bool {
	switch frameType {
	case protocol.TypeTabList, protocol.TypeOutput, protocol.TypeSnapshot,
		protocol.TypeTerminalGridSnapshot:
		return true
	default:
		return false
	}
}

// liveCopies wraps a live frame for each approved viewer:
// viewer_output payload = id length (1 byte) | viewer id | encoded frame.
func (h *viewerHub) liveCopies(frame *protocol.Frame) []*protocol.Frame {
	if !isViewerLiveFrame(frame.Type) {
		return nil
	}
	h.mu.Lock()
	ids := make([]string, 0, len(h.approved))
	for id := range h.approved {
		ids = append(ids, id)
	}
	h.mu.Unlock()
	if len(ids) == 0 {
		return nil
	}
	inner := frame.Encode()
	copies := make([]*protocol.Frame, 0, len(ids))
	for _, id := range ids {
		payload := make([]byte, 0, 1+len(id)+len(inner))
		payload = append(payload, byte(len(id)))
		payload = append(payload, id...)
		payload = append(payload, inner...)
		copies = append(copies, &protocol.Frame{
			Version: 1,
			Type:    protocol.TypeViewerOutput,
			TabID:   frame.TabID,
			Payload: payload,
		})
	}
	return copies
}

// DecodeViewerOutput splits a viewer_output payload (for the relay and tests).
func DecodeViewerOutput(payload []byte) (string, *protocol.Frame, error) {
	if len(payload) < 1 {
		return "", nil, protocol.ErrInsufficientData
	}
	n := int(payload[0])
	if len(payload) < 1+n {
		return "", nil, protocol.ErrInvalidLength
	}
	inner, err := protocol.DecodeFrame(payload[1+n:])
	if err != nil {
		return "", nil, err
	}
	return string(payload[1 : 1+n]), inner, nil
}
