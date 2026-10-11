package viewer

// End to end: the real agent, a fake app on the IPC socket, a running relay
// and this viewer client. Skipped unless a relay and its keyring are given:
//
//	KEYS='{"current":{"id":"e2e","secret":"<base64url of 32 random bytes>"}}'
//	cd services/chau7-relay && npx wrangler dev --port 8787 --var "RELAY_AUTH_KEYS:$KEYS"
//	CHAU7_E2E_RELAY_URL=ws://127.0.0.1:8787 CHAU7_E2E_RELAY_AUTH_KEYS="$KEYS" \
//	  go test ./internal/viewer -run TestEndToEnd -v

import (
	"bufio"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/chau7/chau7-remote/internal/agent"
	"github.com/chau7/chau7-remote/internal/protocol"
)

type lockedBuffer struct {
	mu  sync.Mutex
	buf strings.Builder
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

func writeIPC(conn net.Conn, frame *protocol.Frame) error {
	data := frame.Encode()
	buf := make([]byte, 4+len(data))
	binary.LittleEndian.PutUint32(buf, uint32(len(data))) //nolint:gosec // test frames are small
	copy(buf[4:], data)
	_, err := conn.Write(buf)
	return err
}

func readIPC(r *bufio.Reader) (*protocol.Frame, error) {
	var lenBuf [4]byte
	if _, err := io.ReadFull(r, lenBuf[:]); err != nil {
		return nil, err
	}
	buf := make([]byte, binary.LittleEndian.Uint32(lenBuf[:]))
	if _, err := io.ReadFull(r, buf); err != nil {
		return nil, err
	}
	return protocol.DecodeFrame(buf)
}

func ipcJSON(t *testing.T, frameType uint8, v any) *protocol.Frame {
	t.Helper()
	data, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return &protocol.Frame{Version: 1, Type: frameType, Payload: data}
}

func TestEndToEnd(t *testing.T) {
	relay := os.Getenv("CHAU7_E2E_RELAY_URL")
	keys := os.Getenv("CHAU7_E2E_RELAY_AUTH_KEYS")
	if relay == "" || keys == "" {
		t.Skip("set CHAU7_E2E_RELAY_URL and CHAU7_E2E_RELAY_AUTH_KEYS to run against a relay")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	dir := t.TempDir()
	socketPath := filepath.Join(dir, "remote.sock")
	statePath := filepath.Join(dir, "state.json")
	identity, err := agent.PrepareRelayIdentity(statePath)
	if err != nil {
		t.Fatal(err)
	}
	var keyring agent.RelayKeyring
	if err := json.Unmarshal([]byte(keys), &keyring); err != nil {
		t.Fatal(err)
	}
	credentials, err := agent.DeriveRelayCredentials(keyring, identity.DeviceID, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if err := agent.WritePrivateRelayJSON(filepath.Join(dir, "credentials.json"), credentials, true); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CHAU7_REMOTE_CREDENTIALS", "")
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = listener.Close() }()

	remote, err := agent.NewAgent(socketPath, relay+"/connect", "E2E Mac", statePath)
	if err != nil {
		t.Fatal(err)
	}
	go func() { _ = remote.Run(ctx) }()

	app, err := listener.Accept()
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = app.Close() }()
	appReader := bufio.NewReader(app)
	appFrames := make(chan *protocol.Frame, 64)
	go func() {
		for {
			frame, err := readIPC(appReader)
			if err != nil {
				close(appFrames)
				return
			}
			appFrames <- frame
		}
	}()

	code := fmt.Sprintf("%08x", time.Now().UnixNano()&0xffffffff)
	if err := writeIPC(app, ipcJSON(t, protocol.TypeViewerShare, map[string]any{"share_code": code, "max_viewers": 2})); err != nil {
		t.Fatal(err)
	}

	// The agent connects to the relay and registers the code; retry the
	// viewer until the code is known.
	var out, logs lockedBuffer
	viewerDone := make(chan error, 1)
	go func() {
		for {
			err := Run(ctx, Config{RelayURL: relay, Code: code, ViewerID: "e2e-viewer", Name: "E2E", Output: &out, Log: &logs})
			if err != nil && strings.Contains(err.Error(), "404") && ctx.Err() == nil {
				time.Sleep(300 * time.Millisecond)
				continue
			}
			viewerDone <- err
			return
		}
	}()

	// The app hears the join and approves it.
	var join struct {
		ViewerID  string `json:"viewer_id"`
		Name      string `json:"name"`
		ShareCode string `json:"share_code"`
	}
	for join.ViewerID == "" {
		select {
		case frame, ok := <-appFrames:
			if !ok {
				t.Fatal("agent closed the IPC socket")
			}
			if frame.Type == protocol.TypeViewerJoin {
				_ = json.Unmarshal(frame.Payload, &join)
			}
		case <-ctx.Done():
			t.Fatalf("no join reached the app; viewer log: %s", logs.String())
		}
	}
	if join.ViewerID != "e2e-viewer" || join.Name != "E2E" || join.ShareCode != code {
		t.Fatalf("unexpected join %+v", join)
	}
	if err := writeIPC(app, ipcJSON(t, protocol.TypeViewerDecision, map[string]any{"viewer_id": join.ViewerID, "approved": true})); err != nil {
		t.Fatal(err)
	}

	// Terminal output reaches the viewer.
	for !strings.Contains(out.String(), "hello from the mac") {
		if err := writeIPC(app, &protocol.Frame{Version: 1, Type: protocol.TypeOutput, TabID: 1, Payload: []byte("hello from the mac\r\n")}); err != nil {
			t.Fatal(err)
		}
		select {
		case err := <-viewerDone:
			t.Fatalf("viewer ended early: %v; log: %s", err, logs.String())
		case <-time.After(200 * time.Millisecond):
		case <-ctx.Done():
			t.Fatalf("no output reached the viewer; log: %s", logs.String())
		}
	}

	// The owner disconnects the viewer.
	if err := writeIPC(app, ipcJSON(t, protocol.TypeViewerLeave, map[string]any{"viewer_id": join.ViewerID})); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-viewerDone:
		if !errors.Is(err, ErrEnded) {
			t.Fatalf("expected the owner to end the viewing, got %v", err)
		}
	case <-ctx.Done():
		t.Fatal("the viewer was not disconnected")
	}
}
