// Package viewer is a minimal read-only viewer client
// (docs/remote-control/VIEWER-PROTOCOL.md), a debug tool that proves the
// viewer path end to end: it opens <relay>/view/<code>, sends VIEWER_JOIN,
// waits for the owner's decision, then writes the shared terminal output
// to a writer until the owner or the viewer ends the viewing.
package viewer

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/coder/websocket"

	"github.com/chau7/chau7-remote/internal/protocol"
)

// Config of one viewing.
type Config struct {
	// RelayURL is the agent's relay URL (CHAU7_RELAY_URL, ending in
	// /connect) or the relay's base URL.
	RelayURL string
	Code     string
	ViewerID string
	Name     string
	// Output receives the terminal output (OUTPUT and SNAPSHOT payloads).
	Output io.Writer
	// Log receives status lines (decision, tab list, end).
	Log io.Writer
}

const websocketCloseTimeout = 2 * time.Second

// ErrDenied is returned when the owner (or the agent) rejects the viewer.
type ErrDenied struct{ Reason string }

func (e ErrDenied) Error() string { return "viewer rejected: " + e.Reason }

// ViewURL builds the relay's viewer URL from the agent's relay URL.
func ViewURL(relayURL, code string) string {
	base := strings.TrimSuffix(strings.TrimSpace(relayURL), "/")
	base = strings.TrimSuffix(base, "/connect")
	return fmt.Sprintf("%s/view/%s", base, strings.ToLower(strings.TrimSpace(code)))
}

type joinPayload struct {
	ViewerID  string `json:"viewer_id"`
	Name      string `json:"name"`
	ShareCode string `json:"share_code"`
}

type decisionPayload struct {
	ViewerID string `json:"viewer_id"`
	Approved bool   `json:"approved"`
	Reason   string `json:"reason"`
}

// JoinFrame is the encoded VIEWER_JOIN a viewer sends first.
func JoinFrame(viewerID, name, code string) []byte {
	data, _ := json.Marshal(joinPayload{ViewerID: viewerID, Name: name, ShareCode: strings.ToLower(code)})
	frame := protocol.Frame{Version: 1, Type: protocol.TypeViewerJoin, Payload: data}
	return frame.Encode()
}

// Session reads relay messages for one viewer and reports what they mean.
type Session struct {
	ViewerID string
	Output   io.Writer
	Log      io.Writer
	Approved bool
}

// ErrEnded is returned when the owner ends the viewing (VIEWER_LEAVE).
var ErrEnded = errors.New("viewing ended by the host")

// Handle processes one message from the relay. It returns ErrDenied or
// ErrEnded when the viewing is over.
func (s *Session) Handle(data []byte) error {
	frame, err := protocol.DecodeFrame(data)
	if err != nil {
		return nil
	}
	switch frame.Type {
	case protocol.TypeViewerDecision:
		var d decisionPayload
		if json.Unmarshal(frame.Payload, &d) != nil {
			return nil
		}
		if !d.Approved {
			return ErrDenied{Reason: d.Reason}
		}
		s.Approved = true
		_, _ = fmt.Fprintln(s.Log, "viewer: approved, showing the shared terminal (read only)")
	case protocol.TypeViewerLeave:
		return ErrEnded
	case protocol.TypeViewerOutput:
		if !s.Approved {
			return nil
		}
		id, inner, err := decodeOutput(frame.Payload)
		if err != nil || id != s.ViewerID {
			return nil
		}
		switch inner.Type {
		case protocol.TypeOutput, protocol.TypeSnapshot:
			_, _ = s.Output.Write(inner.Payload)
		case protocol.TypeTabList:
			_, _ = fmt.Fprintf(s.Log, "viewer: tab list %s\n", inner.Payload)
		default:
			_, _ = fmt.Fprintf(s.Log, "viewer: frame 0x%02x (%d bytes)\n", inner.Type, len(inner.Payload))
		}
	}
	return nil
}

func decodeOutput(payload []byte) (string, *protocol.Frame, error) {
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

// Run connects, joins and shows the viewing until it ends or ctx is done.
func Run(ctx context.Context, cfg Config) error {
	url := ViewURL(cfg.RelayURL, cfg.Code)
	conn, resp, err := websocket.Dial(ctx, url, nil)
	if err != nil {
		if resp != nil {
			return fmt.Errorf("connect %s: %s", url, resp.Status)
		}
		return fmt.Errorf("connect %s: %w", url, err)
	}
	defer func() { _ = conn.Close(websocket.StatusNormalClosure, "viewer closed") }()
	conn.SetReadLimit(16 << 20)
	if err := conn.Write(ctx, websocket.MessageBinary, JoinFrame(cfg.ViewerID, cfg.Name, cfg.Code)); err != nil {
		return fmt.Errorf("send join: %w", err)
	}
	_, _ = fmt.Fprintf(cfg.Log, "viewer: joined %s as %s, waiting for the owner to approve\n", cfg.Code, cfg.ViewerID)
	session := &Session{ViewerID: cfg.ViewerID, Output: cfg.Output, Log: cfg.Log}
	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			if ctx.Err() != nil {
				leave, _ := json.Marshal(map[string]string{"viewer_id": cfg.ViewerID})
				frame := protocol.Frame{Version: 1, Type: protocol.TypeViewerLeave, Payload: leave}
				// ctx is done: send the leave under a fresh deadline.
				writeCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), websocketCloseTimeout)
				_ = conn.Write(writeCtx, websocket.MessageBinary, frame.Encode())
				cancel()
				return nil
			}
			return fmt.Errorf("relay closed: %w", err)
		}
		if err := session.Handle(data); err != nil {
			return err
		}
	}
}
